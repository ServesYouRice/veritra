package storage

import (
	"context"
	"fmt"
	"testing"

	"private-messenger/server/internal/domain"
)

// The cursor other members see never moves backwards, and when the message it
// pointed at is gone it moves only to what the account has read itself.
func TestMarkReadSharedCursorIsMonotonic(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	reader := registerTestMember(t, ctx, store, invite.Code, "reader")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	if err := store.AddConversationMember(ctx, conversation.ID, reader.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add member: %v", err)
	}
	var ids []string
	for i := 0; i < 3; i++ {
		message, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
			ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
			IdempotencyKey: fmt.Sprintf("m%d", i), Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo",
		})
		if err != nil {
			t.Fatalf("save message: %v", err)
		}
		ids = append(ids, message.ID)
	}
	shared := func() string {
		t.Helper()
		var id *string
		if err := store.db.QueryRowContext(ctx, `SELECT shared_message_id FROM read_receipts WHERE account_id = ? AND conversation_id = ?`,
			reader.Account.ID, conversation.ID).Scan(&id); err != nil {
			t.Fatalf("read shared cursor: %v", err)
		}
		if id == nil {
			return "<nil>"
		}
		return *id
	}
	read := func(messageID string) int64 {
		t.Helper()
		eventID, err := store.MarkReadWithSyncEvent(ctx, conversation.ID, reader.Account.ID, messageID)
		if err != nil {
			t.Fatalf("mark read: %v", err)
		}
		return eventID
	}

	if read(ids[1]) == 0 || shared() != ids[1] {
		t.Fatalf("first read: shared=%s", shared())
	}
	if read(ids[0]) != 0 || shared() != ids[1] {
		t.Fatalf("older read moved the shared cursor to %s", shared())
	}
	// The account reads on privately; the announced message is then deleted.
	if err := store.MarkReadPrivate(ctx, conversation.ID, reader.Account.ID, ids[2]); err != nil {
		t.Fatalf("private read: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM message_envelopes WHERE id = ?`, ids[1]); err != nil {
		t.Fatalf("delete announced message: %v", err)
	}
	if got := shared(); got != "<nil>" {
		t.Fatalf("shared cursor after delete: %s", got)
	}
	// An older public read must not announce a cursor behind what is read.
	if read(ids[0]) != 0 || shared() != "<nil>" {
		t.Fatalf("older read after delete announced %s", shared())
	}
	if read(ids[2]) == 0 || shared() != ids[2] {
		t.Fatalf("read of the newest: shared=%s", shared())
	}
}
