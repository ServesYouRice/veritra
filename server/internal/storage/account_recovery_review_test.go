package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
)

// K0 R2 review follow-ups: storage rules.

// A revocation pending in a legacy group (no roster) whose coordinator is
// an old device of an account that then recovers: the coordinator role
// falls back to the lowest eligible device, and the recovered device, which
// has the lowest id but no leaf in the group, must not be it.
func TestRecoveredDeviceNeverCoordinatesAPendingLegacyRevocation(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	addTestDevice(t, ctx, store, bob.Account.ID, coordBob)
	const tablet = "dev-z-owner-tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	makeLegacyMLSGroup(t, ctx, store, conversation.ID, owner)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	var stored string
	if err := store.db.QueryRowContext(ctx, `SELECT coordinator_device_id FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
		conversation.ID, tablet).Scan(&stored); err != nil || stored != coordBob {
		t.Fatalf("stored coordinator = %q, err = %v, want %q", stored, err, coordBob)
	}

	claim := claimTestRecovery(t, ctx, store, bob, 0)
	const lowest = "dev-0-recovered"
	if _, err := store.db.ExecContext(ctx, `UPDATE account_recovery_requests SET device_id = ? WHERE id = ?`, lowest, claim.request.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("legacy-recovered")); err != nil {
		t.Fatalf("complete: %v", err)
	}
	coordinatorOf := func(accountID, deviceID string) string {
		t.Helper()
		items, err := store.ListMLSRevocations(ctx, accountID, deviceID)
		if err != nil {
			t.Fatal(err)
		}
		for _, item := range items {
			if item.ConversationID == conversation.ID && item.RevokedDeviceID == tablet {
				return item.CoordinatorDeviceID
			}
		}
		return ""
	}
	if got := coordinatorOf(bob.Account.ID, lowest); got == lowest {
		t.Fatalf("the recovered device coordinates the tablet's revocation")
	}
	_, _, err = store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: lowest,
		Kind: "commit", Payload: []byte("commit-recovered"), IdempotencyKey: "recovered", RevocationDeviceID: tablet,
	})
	if !errors.Is(err, ErrForbidden) {
		t.Fatalf("commit by the recovered device: err = %v, want %v", err, ErrForbidden)
	}
	if got := coordinatorOf(owner.Account.ID, owner.Device.ID); got != owner.Device.ID {
		t.Fatalf("coordinator after recovery = %q, want the owner's device %q", got, owner.Device.ID)
	}
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Kind: "commit", Payload: []byte("commit-owner"), IdempotencyKey: "owner-fallback", RevocationDeviceID: tablet,
	}); err != nil {
		t.Fatalf("commit by the owner's device: %v", err)
	}
}

// An instance set up after migration 0045 gets its decoy key lazily, from
// crypto/rand, once; later calls read it without the writer.
func TestRecoveryDecoyKeyIsCreatedOnceAndReadWithoutTheWriter(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	createTestOwner(t, ctx, store)
	if _, err := store.db.ExecContext(ctx, `UPDATE instances SET recovery_decoy_key = NULL WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	first, err := store.recoveryDecoyKey(ctx)
	if err != nil || len(first) != 32 {
		t.Fatalf("lazy decoy key = %x, err = %v", first, err)
	}
	if bytes.Equal(first, make([]byte, 32)) {
		t.Fatal("lazy decoy key is all zero")
	}
	var stored []byte
	if err := store.db.QueryRowContext(ctx, `SELECT recovery_decoy_key FROM instances WHERE id = 1`).Scan(&stored); err != nil || !bytes.Equal(stored, first) {
		t.Fatalf("stored key = %x, err = %v, want %x", stored, err, first)
	}

	// Hold the single writer connection: an existing key must still be
	// returned, unchanged, before a short deadline.
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	short, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()
	again, err := store.recoveryDecoyKey(short)
	if err != nil || !bytes.Equal(again, first) {
		t.Fatalf("decoy key while the writer is busy = %x, err = %v, want %x", again, err, first)
	}
}

// Completion ends account-only (restore) sessions as well as the old
// devices' sessions; another account's are untouched.
func TestRecoveryCompletionDeletesAccountOnlySessions(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	now := time.Now().UTC()
	for _, row := range []struct{ token, accountID string }{
		{"owner-restore", owner.Account.ID},
		{"bob-restore", bob.Account.ID},
	} {
		if _, err := store.db.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at)
			VALUES(?, ?, NULL, ?, ?, ?, ?, ?)`, auth.HashToken(row.token), row.accountID, formatTime(now.Add(time.Hour)), formatTime(now), formatTime(now), formatTime(now), formatTime(now.Add(time.Hour))); err != nil {
			t.Fatal(err)
		}
	}
	claim := claimTestRecovery(t, ctx, store, owner, 0)
	if _, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("recovered")); err != nil {
		t.Fatalf("complete: %v", err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE account_id = ? AND device_id IS NULL`, owner.Account.ID); n != 0 {
		t.Fatalf("recovered account kept %d account-only sessions", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE account_id = ? AND device_id IS NULL`, bob.Account.ID); n != 1 {
		t.Fatalf("another account's account-only sessions = %d, want 1", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE token_hash = ?`, auth.HashToken("recovered")); n != 1 {
		t.Fatal("the recovered session is missing")
	}
}

// A claim that replaces a waiting request writes the same cancellation
// audit row as every other cancel.
func TestRecoveryClaimReplacementIsAudited(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	first := claimTestRecovery(t, ctx, store, owner, time.Hour)
	second := claimTestRecovery(t, ctx, store, owner, time.Hour)
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM audit_events WHERE event_type = 'account.recovery_cancelled'
		AND json_extract(metadata_json, '$.request_id') = ? AND json_extract(metadata_json, '$.reason') = ?`,
		first.request.ID, RecoveryCancelledReplaced); n != 1 {
		t.Fatalf("replacement audit rows = %d, want 1", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM audit_events WHERE event_type = 'account.recovery_cancelled'
		AND json_extract(metadata_json, '$.request_id') = ?`, second.request.ID); n != 0 {
		t.Fatalf("the waiting request has %d cancellation audit rows", n)
	}
}

// legacyRecoveryFixture is a legacy group (no roster) of the owner and Bob,
// with coordBob, the lowest pre-existing id, and owner tablets; Bob then
// recovers onto legacyRecovered, which sorts before every other device.
type legacyRecoveryFixture struct {
	store        *Store
	owner, bob   AccountDevice
	conversation string
}

const legacyRecovered = "dev-0-recovered"

func newLegacyRecoveryFixture(t *testing.T, ctx context.Context, tablets []string, revokeBefore bool) legacyRecoveryFixture {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	addTestDevice(t, ctx, store, bob.Account.ID, coordBob)
	for _, tablet := range tablets {
		addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	}
	makeLegacyMLSGroup(t, ctx, store, conversation.ID, owner)
	f := legacyRecoveryFixture{store: store, owner: owner, bob: bob, conversation: conversation.ID}
	if revokeBefore {
		for _, tablet := range tablets {
			f.revoke(t, ctx, tablet)
		}
	}
	claim := claimTestRecovery(t, ctx, store, bob, 0)
	if _, err := store.db.ExecContext(ctx, `UPDATE account_recovery_requests SET device_id = ? WHERE id = ?`, legacyRecovered, claim.request.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("legacy-recovered")); err != nil {
		t.Fatalf("complete: %v", err)
	}
	return f
}

func (f legacyRecoveryFixture) revoke(t *testing.T, ctx context.Context, tablet string) {
	t.Helper()
	if _, err := f.store.RevokeDeviceWithSyncEvent(ctx, f.owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
}

func (f legacyRecoveryFixture) coordinator(t *testing.T, ctx context.Context, tablet string) string {
	t.Helper()
	var coordinator *string
	if err := f.store.db.QueryRowContext(ctx, `SELECT `+mlsRevocationCoordinator("r")+` FROM mls_revocations r
		WHERE r.conversation_id = ? AND r.revoked_device_id = ?`, f.conversation, tablet).Scan(&coordinator); err != nil {
		t.Fatal(err)
	}
	if coordinator == nil {
		return ""
	}
	return *coordinator
}

// A later commit in the group (here the owner's commit for another pending
// revocation) gives the recovered device no leaf, so it must stay
// ineligible.
func TestRecoveredDeviceStaysIneligibleAfterALaterLegacyCommit(t *testing.T) {
	ctx := context.Background()
	const tablet1, tablet2 = "dev-z-owner-tablet1", "dev-z-owner-tablet2"
	f := newLegacyRecoveryFixture(t, ctx, []string{tablet1, tablet2}, true)
	if got := f.coordinator(t, ctx, tablet1); got != f.owner.Device.ID {
		t.Fatalf("tablet1 coordinator = %q, want the owner's device", got)
	}
	if _, _, err := f.store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: f.conversation, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		Kind: "commit", Payload: []byte("commit-tablet1"), IdempotencyKey: "tablet1", RevocationDeviceID: tablet1,
	}); err != nil {
		t.Fatalf("owner's commit for tablet1: %v", err)
	}
	if got := f.coordinator(t, ctx, tablet2); got != f.owner.Device.ID {
		t.Fatalf("tablet2 coordinator after a later commit = %q, want the owner's device %q", got, f.owner.Device.ID)
	}
}

// A revocation queued after recovery in a legacy group neither names the
// recovered device as coordinator nor waits for its confirmation; a device
// welcomed into the group later still has to confirm.
func TestLegacyRevocationAfterRecoveryDoesNotWaitOnTheRecoveredDevice(t *testing.T) {
	ctx := context.Background()
	const tablet, welcomed = "dev-z-owner-tablet", "dev-y-bob-welcomed"
	f := newLegacyRecoveryFixture(t, ctx, []string{tablet}, false)
	addTestDevice(t, ctx, f.store, f.bob.Account.ID, welcomed)
	if _, _, err := f.store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: f.conversation, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		RecipientDeviceID: welcomed, Kind: "welcome", Payload: []byte("welcome-later"), IdempotencyKey: "welcome-later",
	}); err != nil {
		t.Fatal(err)
	}
	f.revoke(t, ctx, tablet)
	var stored string
	if err := f.store.db.QueryRowContext(ctx, `SELECT coordinator_device_id FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
		f.conversation, tablet).Scan(&stored); err != nil || stored == legacyRecovered {
		t.Fatalf("stored coordinator = %q, err = %v", stored, err)
	}
	if got := f.coordinator(t, ctx, tablet); got == legacyRecovered || got == "" {
		t.Fatalf("coordinator = %q", got)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE conversation_id = ? AND revoked_device_id = ? AND device_id = ?`,
		f.conversation, tablet, legacyRecovered); n != 0 {
		t.Fatal("the recovered device must confirm the revocation")
	}
	for _, device := range []string{f.owner.Device.ID, welcomed} {
		if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE conversation_id = ? AND revoked_device_id = ? AND device_id = ?`,
			f.conversation, tablet, device); n != 1 {
			t.Fatalf("%s is not a required confirmer", device)
		}
	}
}
