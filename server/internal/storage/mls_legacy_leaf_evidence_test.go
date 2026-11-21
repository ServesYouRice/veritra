package storage

import (
	"context"
	"fmt"
	"testing"
	"time"

	"private-messenger/server/migrations"
)

// K0-R known limit, closed (migration 0096): a legacy group's leaf evidence
// survives retention. Before, "no newer than the oldest retained MLS message"
// moved forward as retention pruned the oldest messages, until it admitted a
// device recovered through K0 (which never has a leaf) as coordinator and as
// required confirmer.

// pruneLegacyMessagesBefore prunes the way retention does: sync events older
// than the message, whose MLS message rows go with them (ON DELETE CASCADE).
func pruneLegacyMessagesBefore(t *testing.T, ctx context.Context, store *Store, conversationID, keepFromIdempotencyKey string) {
	t.Helper()
	var createdAt string
	if err := store.db.QueryRowContext(ctx, `SELECT created_at FROM conversation_mls_messages WHERE conversation_id = ? AND idempotency_key = ?`,
		conversationID, keepFromIdempotencyKey).Scan(&createdAt); err != nil {
		t.Fatal(err)
	}
	if _, err := store.PruneSyncEvents(ctx, parseTime(createdAt)); err != nil {
		t.Fatal(err)
	}
}

func legacyCommit(t *testing.T, ctx context.Context, f legacyRecoveryFixture, key string) {
	t.Helper()
	time.Sleep(2 * time.Millisecond)
	if _, _, err := f.store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: f.conversation, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		Kind: "commit", Payload: []byte("commit-" + key), IdempotencyKey: key,
	}); err != nil {
		t.Fatal(err)
	}
}

func legacyEvidence(t *testing.T, ctx context.Context, store *Store, conversationID, deviceID string) bool {
	t.Helper()
	return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_legacy_leaf_evidence WHERE conversation_id = ? AND device_id = ?`, conversationID, deviceID) == 1
}

// The recovered device is created after the group's first message. Once
// retention has pruned every message older than a later one, the old rule
// ("created no later than the oldest retained message") admitted it. It must
// stay ineligible: as the stored coordinator, as the fallback coordinator and
// as a required confirmer.
func TestRecoveredDeviceStaysIneligibleAfterRetentionPrunesTheOlderMessages(t *testing.T) {
	ctx := context.Background()
	const tablet = "dev-z-owner-tablet"
	f := newLegacyRecoveryFixture(t, ctx, []string{tablet}, false)
	legacyCommit(t, ctx, f, "later-1")
	legacyCommit(t, ctx, f, "later-2")
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM conversation_mls_messages WHERE conversation_id = ?`, f.conversation); n != 3 {
		t.Fatalf("messages before the prune = %d, want 3", n)
	}
	pruneLegacyMessagesBefore(t, ctx, f.store, f.conversation, "later-2")
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM conversation_mls_messages WHERE conversation_id = ?`, f.conversation); n != 1 {
		t.Fatalf("messages after the prune = %d, want only the newest", n)
	}
	// The premise: the old rule would now admit the recovered device.
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM devices d WHERE d.id = ? AND d.created_at <= (SELECT MIN(created_at) FROM conversation_mls_messages WHERE conversation_id = ?)`,
		legacyRecovered, f.conversation); n != 1 {
		t.Fatal("test premise: the recovered device is no newer than the oldest retained message")
	}
	if legacyEvidence(t, ctx, f.store, f.conversation, legacyRecovered) {
		t.Fatal("the recovered device has evidence of a leaf")
	}
	// A revocation queued now names a coordinator and confirmers other than it.
	f.revoke(t, ctx, tablet)
	var stored string
	if err := f.store.db.QueryRowContext(ctx, `SELECT coordinator_device_id FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
		f.conversation, tablet).Scan(&stored); err != nil || stored == legacyRecovered {
		t.Fatalf("stored coordinator = %q, err = %v", stored, err)
	}
	if got := f.coordinator(t, ctx, tablet); got == legacyRecovered || got == "" {
		t.Fatalf("coordinator after the prune = %q", got)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE conversation_id = ? AND revoked_device_id = ? AND device_id = ?`,
		f.conversation, tablet, legacyRecovered); n != 0 {
		t.Fatal("the recovered device must not confirm the revocation")
	}
	// Its own commit for the revocation is refused.
	if _, _, err := f.store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: f.conversation, SenderAccountID: f.bob.Account.ID, SenderDeviceID: legacyRecovered,
		Kind: "commit", Payload: []byte("commit-recovered"), IdempotencyKey: "recovered-after-prune", RevocationDeviceID: tablet,
	}); err == nil {
		t.Fatal("the recovered device committed the revocation")
	}
}

// A device welcomed into the legacy group after its first message keeps its
// evidence when retention prunes the Welcome (a mark frozen at the first
// message alone would drop it and leave revocations with no coordinator).
func TestWelcomedDeviceKeepsItsEvidenceAfterItsWelcomeIsPruned(t *testing.T) {
	ctx := context.Background()
	const welcomed = "dev-y-bob-welcomed"
	f := newLegacyRecoveryFixture(t, ctx, nil, false)
	legacyCommit(t, ctx, f, "before-welcome")
	addTestDevice(t, ctx, f.store, f.bob.Account.ID, welcomed)
	time.Sleep(2 * time.Millisecond)
	if _, _, err := f.store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: f.conversation, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		RecipientDeviceID: welcomed, Kind: "welcome", Payload: []byte("welcome-w"), IdempotencyKey: "welcome-w",
	}); err != nil {
		t.Fatal(err)
	}
	legacyCommit(t, ctx, f, "after-welcome")
	pruneLegacyMessagesBefore(t, ctx, f.store, f.conversation, "after-welcome")
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM conversation_mls_messages WHERE conversation_id = ? AND kind = 'welcome'`, f.conversation); n != 0 {
		t.Fatal("test premise: the Welcome was pruned")
	}
	if !legacyEvidence(t, ctx, f.store, f.conversation, welcomed) {
		t.Fatal("the welcomed device lost its evidence with its Welcome")
	}
	if !legacyEvidence(t, ctx, f.store, f.conversation, f.owner.Device.ID) {
		t.Fatal("the sender lost its evidence")
	}
	if legacyEvidence(t, ctx, f.store, f.conversation, legacyRecovered) {
		t.Fatal("the recovered device has evidence")
	}
	// Bob's device that existed at the first message is still a leaf holder.
	if !legacyEvidence(t, ctx, f.store, f.conversation, coordBob) {
		t.Fatal("a device older than the group's first message lost its evidence")
	}
}

// Evidence is only recorded for a conversation without a roster, and goes
// with its conversation and its device.
func TestLegacyEvidenceIsNotKeptForRosteredGroups(t *testing.T) {
	ctx := context.Background()
	store, owner, conversation, tablet := newCoordinatorOnlyRevocation(t, ctx)
	defer store.Close()
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_legacy_leaf_evidence WHERE conversation_id = ?`, conversation.ID); n != 0 {
		t.Fatalf("a rostered group has %d legacy evidence rows", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_legacy_marks WHERE conversation_id = ?`, conversation.ID); n != 0 {
		t.Fatalf("a rostered group has %d legacy marks", n)
	}
	_ = owner
	_ = tablet
}

// Upgrade: migration 0096 seeds the evidence from the messages still
// retained, by the three old rules; a device created after the group's first
// message and named by neither a send nor a Welcome gets none.
func TestMigration0096SeedsLegacyEvidenceFromRetainedMessages(t *testing.T) {
	ctx := context.Background()
	store, _ := openBareStoreAt(t)
	old, _ := migrationsUpTo(t, "0095")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	const day = "2026-0%d-0%dT00:00:00.000000000Z"
	at := func(month, d int) string { return fmtDay(day, month, d) }
	for _, statement := range []string{
		`INSERT INTO instances(id, name, setup_complete, created_at, updated_at) VALUES(1, 'Old', 1, '` + at(1, 1) + `', '` + at(1, 1) + `')`,
		`INSERT INTO accounts(id, username, password_hash, role, status, created_at) VALUES('a_o', 'owner', 'h', 'owner', 'active', '` + at(1, 1) + `')`,
		`INSERT INTO accounts(id, username, password_hash, role, status, created_at) VALUES('a_b', 'bob', 'h', 'member', 'active', '` + at(1, 1) + `')`,
		`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_o', 'a_o', 'o', X'01', '` + at(1, 1) + `')`,
		`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_old', 'a_b', 'b', X'01', '` + at(1, 2) + `')`,
		`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_new', 'a_b', 'b', X'01', '` + at(3, 1) + `')`,
		`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_w', 'a_b', 'b', X'01', '` + at(3, 1) + `')`,
		`INSERT INTO conversations(id, kind, title, created_by, created_at) VALUES('conv_legacy', 'group', 'g', 'a_o', '` + at(1, 3) + `')`,
		`INSERT INTO conversations(id, kind, title, created_by, created_at) VALUES('conv_rostered', 'group', 'g', 'a_o', '` + at(1, 3) + `')`,
		`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('m1', 'a_o', 'conv_legacy', 'owner', '` + at(1, 3) + `')`,
		`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('m2', 'a_b', 'conv_legacy', 'member', '` + at(1, 3) + `')`,
		`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('m3', 'a_o', 'conv_rostered', 'owner', '` + at(1, 3) + `')`,
		`INSERT INTO conversation_mls_groups(conversation_id, epoch, updated_at) VALUES('conv_rostered', 0, '` + at(1, 3) + `')`,
		`INSERT INTO conversation_mls_messages(id, conversation_id, sender_account_id, sender_device_id, kind, payload, idempotency_key, created_at) VALUES('mls1', 'conv_legacy', 'a_o', 'dev_o', 'commit', X'01', 'k1', '` + at(2, 1) + `')`,
		`INSERT INTO conversation_mls_messages(id, conversation_id, sender_account_id, sender_device_id, recipient_device_id, kind, payload, idempotency_key, created_at) VALUES('mls2', 'conv_legacy', 'a_o', 'dev_o', 'dev_w', 'welcome', X'01', 'k2', '` + at(3, 2) + `')`,
		`INSERT INTO conversation_mls_messages(id, conversation_id, sender_account_id, sender_device_id, kind, payload, idempotency_key, created_at) VALUES('mls3', 'conv_rostered', 'a_o', 'dev_o', 'commit', X'01', 'k3', '` + at(2, 1) + `')`,
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatalf("seed %q: %v", statement[:40], err)
		}
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	has := func(conversation, device string) bool {
		return legacyEvidence(t, ctx, store, conversation, device)
	}
	for _, device := range []string{"dev_o", "dev_old", "dev_w"} {
		if !has("conv_legacy", device) {
			t.Errorf("%s has no seeded evidence in the legacy group", device)
		}
	}
	if has("conv_legacy", "dev_new") {
		t.Error("a device created after the first message, with no send or Welcome, was seeded")
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_legacy_leaf_evidence WHERE conversation_id = 'conv_rostered'`); n != 0 {
		t.Errorf("the rostered group was seeded with %d rows", n)
	}
	var mark string
	if err := store.db.QueryRowContext(ctx, `SELECT oldest_message_at FROM mls_legacy_marks WHERE conversation_id = 'conv_legacy'`).Scan(&mark); err != nil || mark != at(2, 1) {
		t.Errorf("mark = %q, err = %v, want the first retained message %q", mark, err, at(2, 1))
	}
}

func fmtDay(layout string, month, day int) string {
	return fmt.Sprintf(layout, month, day)
}
