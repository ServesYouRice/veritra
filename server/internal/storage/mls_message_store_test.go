package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

func TestMLSMessagesAreScopedIdempotentAndAtomic(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "member")
	outsider := registerTestMember(t, ctx, store, invite.Code, "outsider")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{member.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}

	input := CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID,
		SenderDeviceID: owner.Device.ID, RecipientDeviceID: member.Device.ID,
		Kind: "welcome", Payload: []byte("synthetic-mls-welcome"), IdempotencyKey: "welcome-1",
	}
	welcome, duplicate, err := store.CreateMLSMessage(ctx, input)
	if err != nil || duplicate || welcome.SyncEventID == 0 {
		t.Fatalf("create welcome: message=%#v duplicate=%v err=%v", welcome, duplicate, err)
	}
	if retry, duplicate, err := store.CreateMLSMessage(ctx, input); err != nil || !duplicate || retry.ID != welcome.ID {
		t.Fatalf("idempotent retry: message=%#v duplicate=%v err=%v", retry, duplicate, err)
	}
	changed := input
	changed.Payload = []byte("different")
	if _, _, err := store.CreateMLSMessage(ctx, changed); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("changed retry err=%v", err)
	}
	if _, err := store.MLSMessage(ctx, welcome.ID, owner.Account.ID, owner.Device.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-recipient fetch err=%v", err)
	}
	if fetched, err := store.MLSMessage(ctx, welcome.ID, member.Account.ID, member.Device.ID); err != nil || !bytes.Equal(fetched.Payload, input.Payload) {
		t.Fatalf("recipient fetch=%#v err=%v", fetched, err)
	}

	invalidTarget := input
	invalidTarget.IdempotencyKey = "welcome-outsider"
	invalidTarget.RecipientDeviceID = outsider.Device.ID
	if _, _, err := store.CreateMLSMessage(ctx, invalidTarget); !errors.Is(err, ErrForbidden) {
		t.Fatalf("outsider target err=%v", err)
	}
	commit, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID,
		SenderDeviceID: owner.Device.ID, Kind: "commit",
		Payload: []byte("synthetic-mls-commit"), IdempotencyKey: "commit-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	listed, err := store.ListMLSMessages(ctx, member.Account.ID, member.Device.ID, welcome.SyncEventID, 10)
	if err != nil || len(listed) != 1 || listed[0].ID != commit.ID {
		t.Fatalf("list messages=%#v err=%v", listed, err)
	}

	if _, err := store.db.ExecContext(ctx, `CREATE TRIGGER fail_mls_sync BEFORE INSERT ON sync_events BEGIN SELECT RAISE(FAIL, 'forced'); END`); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID,
		SenderDeviceID: owner.Device.ID, Kind: "commit",
		Payload: []byte("rolled-back"), IdempotencyKey: "commit-rollback",
	}); err == nil {
		t.Fatal("expected sync-event failure")
	}
	var count int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversation_mls_messages WHERE idempotency_key = 'commit-rollback'`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("rolled-back message count=%d err=%v", count, err)
	}
}
