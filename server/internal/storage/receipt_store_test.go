package storage

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"private-messenger/server/internal/domain"
)

func createdEvent(t *testing.T, conversationID string, message domain.MessageEnvelope) domain.SyncEvent {
	t.Helper()
	payload, err := json.Marshal(messageSyncEventPayload(message))
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	return domain.SyncEvent{ID: 1, Type: "message.envelope.created", ConversationID: conversationID, Payload: payload}
}

// Delivery cursors are kept for a group of ReceiptMaxMembers and refused for
// one member more, so a delivery is never announced to a large group.
func TestDeliveryCursorsStopPastTheMemberCap(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, ReceiptMaxMembers, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	var members []AccountDevice
	for i := 0; i < ReceiptMaxMembers-1; i++ {
		member := registerTestMember(t, ctx, store, invite.Code, fmt.Sprintf("member%02d", i))
		if err := store.AddConversationMember(ctx, conversation.ID, member.Account.ID, domain.RoleMember); err != nil {
			t.Fatalf("add member: %v", err)
		}
		members = append(members, member)
	}
	// The owner plus 19 members is 20: at the cap.
	message, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		IdempotencyKey: "m1", Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo",
	})
	if err != nil {
		t.Fatalf("save message: %v", err)
	}
	event := createdEvent(t, conversation.ID, message)
	advanced, err := store.RecordDelivered(ctx, members[0].Account.ID, []domain.SyncEvent{event})
	if err != nil || len(advanced) != 1 {
		t.Fatalf("at the cap: advanced=%v err=%v", advanced, err)
	}
	// The same page again moves nothing.
	if advanced, err = store.RecordDelivered(ctx, members[0].Account.ID, []domain.SyncEvent{event}); err != nil || len(advanced) != 0 {
		t.Fatalf("repeat: advanced=%v err=%v", advanced, err)
	}
	// One more member and the group is over the cap.
	extra := registerTestMember(t, ctx, store, invite.Code, "member-extra")
	if err := store.AddConversationMember(ctx, conversation.ID, extra.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add extra member: %v", err)
	}
	if advanced, err = store.RecordDelivered(ctx, members[1].Account.ID, []domain.SyncEvent{event}); err != nil || len(advanced) != 0 {
		t.Fatalf("over the cap: advanced=%v err=%v", advanced, err)
	}
	if receipts, err := store.ConversationReceipts(ctx, conversation.ID, owner.Account.ID); err != nil || len(receipts) != 0 {
		t.Fatalf("over the cap listing: %v err=%v", receipts, err)
	}
}
