package storage

import (
	"context"
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
