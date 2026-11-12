package storage

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/domain"
)

// selfUpdate submits an update-only commit bundle: a commit that adds and
// removes no one (periodic self-update).
func selfUpdate(ctx context.Context, store *Store, conversationID string, sender AccountDevice, epoch int64, key string) (MLSCommitBundleResult, error) {
	return store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversationID, SenderAccountID: sender.Account.ID, SenderDeviceID: sender.Device.ID,
		Epoch: epoch, IdempotencyKey: key, Commit: []byte("update-" + key),
	})
}

func admissionRejections(store *Store, limit string) int64 {
	var count int64
	store.AdmissionCounters().Each(func(name string, rejected int64) {
		if name == limit {
			count = rejected
		}
	})
	return count
}

// Before periodic self-update, the server refused every commit that added
// and removed no one, so a device's leaf keys were refreshed only when it
// happened to remove someone.
func TestMLSUpdateOnlyCommitIsOrderedLikeAnyCommitAndBudgeted(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	carol := registerTestMember(t, ctx, store, invite.Code, "carol")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID, carol.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	// No group yet: there is nothing to update.
	if _, err := selfUpdate(ctx, store, conversation.ID, owner, 0, "too-early"); !errors.Is(err, ErrMLSNotInGroup) {
		t.Fatalf("update before the group exists err=%v", err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}},
	}); err != nil {
		t.Fatal(err)
	}

	// Bob's update-only commit on the current epoch is accepted.
	first, err := selfUpdate(ctx, store, conversation.ID, bob, 1, "bob-update-1")
	if err != nil || first.Epoch != 2 || first.Commit == nil || len(first.Welcomes) != 0 || first.Duplicate {
		t.Fatalf("update-only commit=%#v err=%v", first, err)
	}
	// It changes no one's place in the roster, and the others receive it.
	var active int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversation_mls_devices
		WHERE conversation_id = ? AND removed_after_event_id IS NULL`, conversation.ID).Scan(&active); err != nil || active != 2 {
		t.Fatalf("active roster=%d err=%v", active, err)
	}
	if events := syncEventIDs(t, ctx, store, owner.Account.ID, owner.Device.ID); events[first.Commit.SyncEventID] != "mls.message.created" {
		t.Fatalf("owner does not see the update commit: %v", events)
	}

	// A lost answer is retried with the same key: the stored commit comes
	// back, inside the budget window and on a moved epoch.
	retry, err := selfUpdate(ctx, store, conversation.ID, bob, 1, "bob-update-1")
	if err != nil || !retry.Duplicate || retry.Commit.ID != first.Commit.ID {
		t.Fatalf("retry=%#v err=%v", retry, err)
	}
	// A stale epoch loses, as for every commit.
	if _, err := selfUpdate(ctx, store, conversation.ID, owner, 1, "owner-stale"); !errors.Is(err, ErrMLSEpochConflict) {
		t.Fatalf("stale update err=%v", err)
	}
	// Bob's next one inside the interval is refused with the time to wait.
	before := admissionRejections(store, admission.SelfUpdates)
	_, err = selfUpdate(ctx, store, conversation.ID, bob, 2, "bob-update-2")
	wait, limited := MLSSelfUpdateRetryAfter(err)
	if !errors.Is(err, ErrMLSSelfUpdateLimit) || !limited || wait <= 50*time.Minute || wait > time.Hour {
		t.Fatalf("second update err=%v wait=%v", err, wait)
	}
	if after := admissionRejections(store, admission.SelfUpdates); after != before+1 {
		t.Fatalf("self-update rejections %d -> %d", before, after)
	}
	// The budget is per device: the owner may update on the same epoch.
	if result, err := selfUpdate(ctx, store, conversation.ID, owner, 2, "owner-update"); err != nil || result.Epoch != 3 {
		t.Fatalf("owner update=%#v err=%v", result, err)
	}
	// Once the interval has passed Bob may update again.
	if _, err := store.db.ExecContext(ctx, `UPDATE conversation_mls_devices SET last_self_update_at = ?
		WHERE conversation_id = ? AND device_id = ?`,
		formatTime(time.Now().UTC().Add(-61*time.Minute)), conversation.ID, bob.Device.ID); err != nil {
		t.Fatal(err)
	}
	if result, err := selfUpdate(ctx, store, conversation.ID, bob, 3, "bob-update-3"); err != nil || result.Epoch != 4 {
		t.Fatalf("update after the interval=%#v err=%v", result, err)
	}
	// Carol is a member but not in the group: she cannot commit.
	if _, err := selfUpdate(ctx, store, conversation.ID, carol, 4, "carol"); !errors.Is(err, ErrMLSNotInGroup) {
		t.Fatalf("outsider update err=%v", err)
	}
	// Other validation is unchanged: a Welcome or a revocation needs a
	// declared device, so neither can ride on an update-only commit.
	for name, input := range map[string]MLSCommitBundleInput{
		"welcome": {Epoch: 4, IdempotencyKey: "w", Commit: []byte("c"), Welcome: []byte("w")},
		"revocation": {Epoch: 4, IdempotencyKey: "r", Commit: []byte("c"),
			RevocationDeviceID: bob.Device.ID},
	} {
		input.ConversationID = conversation.ID
		input.SenderAccountID = owner.Account.ID
		input.SenderDeviceID = owner.Device.ID
		if _, err := store.CreateMLSCommitBundle(ctx, input); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("%s err=%v", name, err)
		}
	}
}

// A removal the group still owes goes first: an update-only commit must not
// take the epoch a revocation or a departed account's removal waits for.
func TestMLSUpdateOnlyCommitWaitsForPendingRemovals(t *testing.T) {
	ctx := context.Background()
	f := newRosteredRevocation(t, ctx)
	bob := AccountDevice{Account: f.bob.Account}
	bob.Device.ID = coordBob
	carol := AccountDevice{Account: f.carol.Account}
	carol.Device.ID = coordCarol

	// Carol's tablet was revoked; its revocation is pending.
	if _, err := selfUpdate(ctx, f.store, f.conversation.ID, f.owner, 1, "owner-1"); !errors.Is(err, ErrMLSChangePending) {
		t.Fatalf("update with a pending revocation err=%v", err)
	}
	if err := f.revocationBundle(ctx, f.bob.Account.ID, coordBob, 1, "revoke-tablet"); err != nil {
		t.Fatal(err)
	}
	if result, err := selfUpdate(ctx, f.store, f.conversation.ID, f.owner, 2, "owner-2"); err != nil || result.Epoch != 3 {
		t.Fatalf("update after the revocation commit=%#v err=%v", result, err)
	}

	// Carol leaves: her device must be removed before anyone updates.
	if _, err := f.store.RemoveConversationMember(ctx, f.conversation.ID, f.owner.Account.ID, f.carol.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := selfUpdate(ctx, f.store, f.conversation.ID, bob, 3, "bob-3"); !errors.Is(err, ErrMLSChangePending) {
		t.Fatalf("update with a pending removal err=%v", err)
	}
	if _, err := f.store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: f.conversation.ID, SenderAccountID: f.bob.Account.ID, SenderDeviceID: coordBob,
		Epoch: 3, IdempotencyKey: "remove-carol", Commit: []byte("remove-carol"),
		Removed: []MLSDeviceRef{{AccountID: carol.Account.ID, DeviceID: coordCarol}},
	}); err != nil {
		t.Fatal(err)
	}
	if result, err := selfUpdate(ctx, f.store, f.conversation.ID, bob, 4, "bob-4"); err != nil || result.Epoch != 5 {
		t.Fatalf("update after the removal=%#v err=%v", result, err)
	}
}

// Owner decision A (2026-11-11): a device whose leave did not go through
// voids the statement it signed with a self-update at once. Its leave
// notice lets one update-only commit pass the interval: only that device's,
// only once per notice, only within LeaveVoidWindow.
func TestMLSSelfUpdateVoidingACancelledLeavePassesTheInterval(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	group, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: group.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}},
	}); err != nil {
		t.Fatal(err)
	}
	epoch := int64(1)
	update := func(who AccountDevice, key string) error {
		result, err := selfUpdate(ctx, store, group.ID, who, epoch, key)
		if err == nil {
			epoch = result.Epoch
		}
		return err
	}
	notice := func(who AccountDevice, key string) {
		t.Helper()
		if _, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
			ConversationID: group.ID, SenderAccountID: who.Account.ID, SenderDeviceID: who.Device.ID,
			IdempotencyKey: key, Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo",
			CryptoMetadata: json.RawMessage(`{"protocol_version":1,"c4_leave":true}`),
		}); err != nil {
			t.Fatalf("notice %s: %v", key, err)
		}
	}
	backdate := func(query string, at time.Time, args ...interface{}) {
		t.Helper()
		if _, err := store.db.ExecContext(ctx, query, append([]interface{}{formatTime(at)}, args...)...); err != nil {
			t.Fatal(err)
		}
	}
	// Periodic updates spend both devices' intervals.
	if err := update(bob, "bob-periodic"); err != nil {
		t.Fatal(err)
	}
	if err := update(owner, "owner-periodic"); err != nil {
		t.Fatal(err)
	}
	if err := update(bob, "bob-too-soon"); !errors.Is(err, ErrMLSSelfUpdateLimit) {
		t.Fatalf("update inside the interval: %v", err)
	}
	// Bob sends his two leave notices; the leave does not go through (he
	// stays a member). His void passes the interval, once.
	notice(bob, "leave")
	notice(bob, "leave-signed")
	if err := update(owner, "owner-on-bobs-notice"); !errors.Is(err, ErrMLSSelfUpdateLimit) {
		t.Fatalf("another device's notice exempted the owner: %v", err)
	}
	if err := update(bob, "void"); err != nil {
		t.Fatalf("void of the cancelled leave refused: %v", err)
	}
	if err := update(bob, "void-again"); !errors.Is(err, ErrMLSSelfUpdateLimit) {
		t.Fatalf("a second update on the same notices: %v", err)
	}
	// A notice older than the window does not exempt, even when it is newer
	// than the last self-update (a longer interval set by the operator).
	store.limits.MLSSelfUpdateMinutes = 3 * 60
	notice(bob, "leave-old")
	backdate(`UPDATE message_envelopes SET created_at = ? WHERE sender_device_id = ?`,
		time.Now().Add(-LeaveVoidWindow-time.Minute), bob.Device.ID)
	backdate(`UPDATE conversation_mls_devices SET last_self_update_at = ? WHERE conversation_id = ? AND device_id = ?`,
		time.Now().Add(-LeaveVoidWindow-2*time.Minute), group.ID, bob.Device.ID)
	if err := update(bob, "stale-notice"); !errors.Is(err, ErrMLSSelfUpdateLimit) {
		t.Fatalf("a notice older than the window exempted: %v", err)
	}
	// The next cancelled leave voids again.
	notice(bob, "leave-2")
	if err := update(bob, "void-2"); err != nil {
		t.Fatalf("void of the second cancelled leave: %v", err)
	}
}
