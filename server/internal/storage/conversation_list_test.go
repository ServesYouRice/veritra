package storage

import (
	"context"
	"testing"
)

// insertRawMessage writes a visible message with an exact id and timestamp, so
// tests can build created_at ties that SaveMessageEnvelope never produces.
func insertRawMessage(t *testing.T, ctx context.Context, store *Store, conversationID string, sender AccountDevice, id, createdAt string) {
	t.Helper()
	if _, err := store.db.ExecContext(ctx, `
		INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at)
		VALUES (?, ?, ?, ?, ?, x'01', 'mls', '{}', '[]', ?)`,
		id, conversationID, sender.Account.ID, sender.Device.ID, id, createdAt); err != nil {
		t.Fatalf("insert message %s: %v", id, err)
	}
}

func TestListConversationsUnreadCountTimestampTies(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	reader := registerTestMember(t, ctx, store, invite.Code, "reader")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{reader.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	tie := formatTime(parseTime("2026-01-01T00:00:00.000000000Z"))
	later := formatTime(parseTime("2026-01-01T00:00:01.000000000Z"))
	insertRawMessage(t, ctx, store, conversation.ID, owner, "msg_tie_a", tie)
	insertRawMessage(t, ctx, store, conversation.ID, owner, "msg_tie_b", tie)
	insertRawMessage(t, ctx, store, conversation.ID, owner, "msg_tie_c", tie)
	unread := func() int64 {
		conversations, err := store.ListConversations(ctx, reader.Account.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range conversations {
			if c.ID == conversation.ID {
				return c.UnreadCount
			}
		}
		t.Fatal("conversation missing from list")
		return 0
	}
	if got := unread(); got != 3 {
		t.Fatalf("unread without a receipt = %d, want 3", got)
	}
	// The receipt points at the middle message of three that share a
	// timestamp: only the one ordered after it is unread.
	if _, err := store.db.ExecContext(ctx, `INSERT INTO read_receipts(account_id, conversation_id, message_id, read_at) VALUES(?, ?, 'msg_tie_b', ?)`, reader.Account.ID, conversation.ID, tie); err != nil {
		t.Fatal(err)
	}
	if got := unread(); got != 1 {
		t.Fatalf("unread after the middle tied message = %d, want 1", got)
	}
	insertRawMessage(t, ctx, store, conversation.ID, owner, "msg_later", later)
	if got := unread(); got != 2 {
		t.Fatalf("unread with a later message = %d, want 2", got)
	}
	// The read cursor at the last tied message leaves only the newer one.
	if _, err := store.db.ExecContext(ctx, `UPDATE read_receipts SET message_id = 'msg_tie_c' WHERE account_id = ? AND conversation_id = ?`, reader.Account.ID, conversation.ID); err != nil {
		t.Fatal(err)
	}
	if got := unread(); got != 1 {
		t.Fatalf("unread after the last tied message = %d, want 1", got)
	}
}
