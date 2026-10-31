package storage

import (
	"context"
	"encoding/json"
	"testing"
)

func TestExportAccountFailsWhenCategoryIterationStopsEarly(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	var ids []string
	for i := 0; i < 2; i++ {
		conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
		if err != nil {
			t.Fatalf("create conversation: %v", err)
		}
		if err := store.SetConversationNotificationMute(ctx, conversation.ID, owner.Account.ID, true, nil); err != nil {
			t.Fatalf("mute conversation: %v", err)
		}
		ids = append(ids, conversation.ID)
	}
	export, err := store.ExportAccount(ctx, owner.Account.ID, ExportAccountOptions{})
	if err != nil {
		t.Fatalf("export with valid rows: %v", err)
	}
	if got := len(export.Categories["notification_preferences"]); got != 2 {
		t.Fatalf("notification_preferences = %d items, want 2", got)
	}
	// The category is read in primary-key order and json(muted) raises a
	// runtime error on malformed text, so the failure happens on the second
	// row, after the first was returned. database/sql reports it only through
	// Rows.Err. The CHECK constraint is bypassed on the pinned writer connection.
	later := ids[0]
	if ids[1] > later {
		later = ids[1]
	}
	conn, err := store.db.writer.Conn(ctx)
	if err != nil {
		t.Fatalf("pin connection: %v", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `PRAGMA ignore_check_constraints = ON`); err != nil {
		t.Fatalf("ignore check constraints: %v", err)
	}
	if _, err := conn.ExecContext(ctx, `UPDATE conversation_notification_preferences SET muted = 'bad' WHERE account_id = ? AND conversation_id = ?`, owner.Account.ID, later); err != nil {
		t.Fatalf("corrupt notification preference: %v", err)
	}
	if _, err := conn.ExecContext(ctx, `PRAGMA ignore_check_constraints = OFF`); err != nil {
		t.Fatalf("restore check constraints: %v", err)
	}
	export, err = store.ExportAccount(ctx, owner.Account.ID, ExportAccountOptions{})
	if err == nil {
		t.Fatalf("export succeeded with a truncated category: %d notification_preferences", len(export.Categories["notification_preferences"]))
	}
}

func testRowCount(t *testing.T, ctx context.Context, store *Store, query string, args ...any) int {
	t.Helper()
	var n int
	if err := store.db.QueryRowContext(ctx, query, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", query, err)
	}
	return n
}

func TestDeleteAccountDataScrubsBlocksKeyPackagesPreferencesAndCalls(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	alice := registerTestMember(t, ctx, store, invite.Code, "alice")
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	dm, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: alice.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatalf("create dm: %v", err)
	}
	for _, id := range []string{alice.Account.ID, bob.Account.ID} {
		if err := store.SetConversationNotificationMute(ctx, dm.ID, id, true, nil); err != nil {
			t.Fatalf("mute for %s: %v", id, err)
		}
	}
	if _, err := store.BlockAccount(ctx, alice.Account.ID, owner.Account.ID); err != nil {
		t.Fatalf("alice blocks owner: %v", err)
	}
	if _, err := store.BlockAccount(ctx, bob.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("bob blocks alice: %v", err)
	}
	if _, err := store.BlockAccount(ctx, bob.Account.ID, owner.Account.ID); err != nil {
		t.Fatalf("bob blocks owner: %v", err)
	}
	ringing, err := store.CreateCallSession(ctx, dm.ID, alice.Account.ID, json.RawMessage(`{"sdp":"alice-offer-secret"}`))
	if err != nil {
		t.Fatalf("alice call: %v", err)
	}
	ended, err := store.CreateCallSession(ctx, dm.ID, alice.Account.ID, json.RawMessage(`{"sdp":"alice-old-offer"}`))
	if err != nil {
		t.Fatalf("alice second call: %v", err)
	}
	if _, err := store.TransitionCallSession(ctx, ended.ID, alice.Account.ID, ended.Version, "ended", nil); err != nil {
		t.Fatalf("end alice call: %v", err)
	}
	bobCall, err := store.CreateCallSession(ctx, dm.ID, bob.Account.ID, json.RawMessage(`{"sdp":"bob-offer"}`))
	if err != nil {
		t.Fatalf("bob call: %v", err)
	}
	aliceKeyPackages := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ?`, alice.Device.ID)
	if aliceKeyPackages == 0 {
		t.Fatal("alice has no seeded key package")
	}
	bobKeyPackages := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ?`, bob.Device.ID)

	if _, err := store.DeleteAccountData(ctx, alice.Account.ID); err != nil {
		t.Fatalf("delete alice: %v", err)
	}

	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM account_blocks WHERE blocker_account_id = ?`, alice.Account.ID); n != 0 {
		t.Errorf("alice still blocks %d accounts", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM account_blocks WHERE blocker_account_id = ? AND blocked_account_id = ?`, bob.Account.ID, alice.Account.ID); n != 1 {
		t.Errorf("bob's block of alice = %d rows, want it kept (another user's data)", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM account_blocks WHERE blocker_account_id = ?`, bob.Account.ID); n != 2 {
		t.Errorf("bob blocks = %d rows, want 2", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ?`, alice.Device.ID); n != 0 {
		t.Errorf("alice device still has %d key packages", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ?`, bob.Device.ID); n != bobKeyPackages {
		t.Errorf("bob key packages = %d, want %d", n, bobKeyPackages)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM conversation_notification_preferences WHERE account_id = ?`, alice.Account.ID); n != 0 {
		t.Errorf("alice still has %d notification preferences", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM conversation_notification_preferences WHERE account_id = ?`, bob.Account.ID); n != 1 {
		t.Errorf("bob notification preferences = %d, want 1", n)
	}
	for _, id := range []string{ringing.ID, ended.ID} {
		var metadata, state string
		var endedAt *string
		if err := store.db.QueryRowContext(ctx, `SELECT metadata_json, state, ended_at FROM call_sessions WHERE id = ?`, id).Scan(&metadata, &state, &endedAt); err != nil {
			t.Fatalf("read alice call %s: %v", id, err)
		}
		if metadata != `{}` {
			t.Errorf("alice call %s metadata = %s, want {}", id, metadata)
		}
		if !isTerminalCallState(state) || endedAt == nil {
			t.Errorf("alice call %s state=%s ended_at=%v, want an ended call", id, state, endedAt)
		}
	}
	var bobMetadata, bobState string
	if err := store.db.QueryRowContext(ctx, `SELECT metadata_json, state FROM call_sessions WHERE id = ?`, bobCall.ID).Scan(&bobMetadata, &bobState); err != nil {
		t.Fatalf("read bob call: %v", err)
	}
	if bobMetadata != `{"sdp":"bob-offer"}` || bobState != "ringing" {
		t.Errorf("bob call changed: metadata=%s state=%s", bobMetadata, bobState)
	}

	export, err := store.ExportAccount(ctx, alice.Account.ID, ExportAccountOptions{})
	if err != nil {
		t.Fatalf("export deleted account: %v", err)
	}
	for _, category := range []string{"account_blocks", "device_key_packages", "notification_preferences"} {
		if got := len(export.Categories[category]); got != 0 {
			t.Errorf("export category %s has %d items after deletion", category, got)
		}
	}
	for _, raw := range export.Categories["calls"] {
		var call struct {
			Metadata json.RawMessage `json:"metadata"`
		}
		if err := json.Unmarshal(raw, &call); err != nil {
			t.Fatalf("decode exported call: %v", err)
		}
		if string(call.Metadata) != `{}` {
			t.Errorf("exported call metadata = %s, want {}", call.Metadata)
		}
	}
}
