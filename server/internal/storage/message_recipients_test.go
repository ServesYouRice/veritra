package storage

import (
	"context"
	"sort"
	"testing"

	"private-messenger/server/internal/domain"
)

// The realtime snapshot goes to the accounts that may see the envelope; an
// account that blocked the sender is not one, as for every read path.
func TestMessageRecipientSnapshotOmitsAccountsThatBlockedTheSender(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	sender := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, sender.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	blocker := registerTestMember(t, ctx, store, invite.Code, "blocker")
	other := registerTestMember(t, ctx, store, invite.Code, "other")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: sender.Account.ID, MemberAccountIDs: []string{blocker.Account.ID, other.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.BlockAccount(ctx, blocker.Account.ID, sender.Account.ID); err != nil {
		t.Fatal(err)
	}
	_, _, _, recipients, err := store.SaveMessageEnvelopeWithSyncEventAndRecipients(ctx, domain.MessageEnvelope{
		ConversationID: conversation.ID, SenderAccountID: sender.Account.ID, SenderDeviceID: sender.Device.ID,
		IdempotencyKey: "recipients", Ciphertext: []byte("ciphertext"), CryptoProtocol: "mls-openmls-todo",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{sender.Account.ID, other.Account.ID}
	sort.Strings(want)
	if len(recipients) != len(want) || recipients[0] != want[0] || recipients[1] != want[1] {
		t.Fatalf("recipients = %v, want the sender (for its other devices) and the member who did not block: %v", recipients, want)
	}
	// Blocking is one way: the sender blocking someone does not hide the
	// sender's own message from the one it blocked.
	if _, err := store.BlockAccount(ctx, sender.Account.ID, other.Account.ID); err != nil {
		t.Fatal(err)
	}
	_, _, _, recipients, err = store.SaveMessageEnvelopeWithSyncEventAndRecipients(ctx, domain.MessageEnvelope{
		ConversationID: conversation.ID, SenderAccountID: sender.Account.ID, SenderDeviceID: sender.Device.ID,
		IdempotencyKey: "recipients-2", Ciphertext: []byte("ciphertext"), CryptoProtocol: "mls-openmls-todo",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(recipients) != 2 {
		t.Fatalf("recipients after the sender blocked a member = %v, want unchanged", recipients)
	}
}
