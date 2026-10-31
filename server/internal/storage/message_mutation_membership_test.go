package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

// Editing or deleting needs the same standing as sending: membership of the
// message's conversation now, not only having written the message once.
func TestEditAndDeleteRequireCurrentConversationMembership(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	leaver := registerTestMember(t, ctx, store, invite.Code, "leaver")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{leaver.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	send := func(account AccountDevice, key string) domain.MessageEnvelope {
		t.Helper()
		message, _, _, err := store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{
			ConversationID: conversation.ID, SenderAccountID: account.Account.ID, SenderDeviceID: account.Device.ID,
			IdempotencyKey: key, Ciphertext: []byte("original-" + key), CryptoProtocol: "mls-openmls-todo",
		})
		if err != nil {
			t.Fatal(err)
		}
		return message
	}
	leavers := send(leaver, "leaver-message")
	members := send(owner, "member-message")
	if _, err := store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversation.ID, leaver.Account.ID); err != nil {
		t.Fatal(err)
	}
	events := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events`)

	if _, _, err := store.UpdateMessageEnvelopeWithSyncEvent(ctx, leavers.ID, leaver.Account.ID, []byte("rewritten"), "mls-openmls-todo", nil); !errors.Is(err, ErrForbidden) {
		t.Fatalf("edit after leaving: err = %v, want %v", err, ErrForbidden)
	}
	if _, _, err := store.DeleteMessageEnvelopeWithSyncEvent(ctx, leavers.ID, leaver.Account.ID, []byte("marker"), "mls-openmls-todo", nil); !errors.Is(err, ErrForbidden) {
		t.Fatalf("delete after leaving: err = %v, want %v", err, ErrForbidden)
	}
	var ciphertext []byte
	var deletedAt, editedAt *string
	if err := store.db.QueryRowContext(ctx, `SELECT ciphertext, deleted_at, edited_at FROM message_envelopes WHERE id = ?`, leavers.ID).Scan(&ciphertext, &deletedAt, &editedAt); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(ciphertext, []byte("original-leaver-message")) || deletedAt != nil || editedAt != nil {
		t.Fatalf("a removed member changed its message: ciphertext=%q deleted=%v edited=%v", ciphertext, deletedAt, editedAt)
	}
	if got := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events`); got != events {
		t.Fatalf("sync events %d -> %d, want no event for a refused mutation", events, got)
	}

	// Current members still change their own messages, and only their own.
	if _, _, err := store.UpdateMessageEnvelopeWithSyncEvent(ctx, members.ID, owner.Account.ID, []byte("edited"), "mls-openmls-todo", nil); err != nil {
		t.Fatalf("member edits own message: %v", err)
	}
	if _, _, err := store.DeleteMessageEnvelopeWithSyncEvent(ctx, members.ID, owner.Account.ID, []byte("marker"), "mls-openmls-todo", nil); err != nil {
		t.Fatalf("member deletes own message: %v", err)
	}
	if _, _, err := store.UpdateMessageEnvelopeWithSyncEvent(ctx, members.ID, leaver.Account.ID, []byte("not mine"), "mls-openmls-todo", nil); !errors.Is(err, ErrForbidden) {
		t.Fatalf("edit of someone else's message: err = %v, want %v", err, ErrForbidden)
	}
	// A missing or expired message is still not found.
	past := time.Now().UTC().Add(-time.Minute)
	expired, _, _, err := store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		IdempotencyKey: "already-expired", Ciphertext: []byte("old"), CryptoProtocol: "mls-openmls-todo", ExpiresAt: &past,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.UpdateMessageEnvelopeWithSyncEvent(ctx, expired.ID, owner.Account.ID, []byte("x"), "mls-openmls-todo", nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("edit of an expired message: err = %v, want %v", err, ErrNotFound)
	}
	if _, _, err := store.DeleteMessageEnvelopeWithSyncEvent(ctx, "msg_missing", owner.Account.ID, []byte("x"), "mls-openmls-todo", nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete of a missing message: err = %v, want %v", err, ErrNotFound)
	}
}
