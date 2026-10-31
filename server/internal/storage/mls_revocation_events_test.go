package storage

import (
	"context"
	"testing"

	"private-messenger/server/internal/domain"
)

func completedRevocationEvents(t *testing.T, ctx context.Context, store *Store, conversationID, deviceID string) int {
	t.Helper()
	return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'mls.revocation.completed' AND conversation_id = ? AND json_extract(payload_json, '$.device_id') = ?`, conversationID, deviceID)
}

// A rostered group of the owner's two devices: the owner's phone is the only
// device that has to confirm the tablet's revocation, and it is the
// coordinator, so submitting the commit completes the revocation at once.
func newCoordinatorOnlyRevocation(t *testing.T, ctx context.Context) (*Store, AccountDevice, domain.Conversation, string) {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	const tablet = "dev_owner_tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: owner.Account.ID, DeviceID: tablet}},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	return store, owner, conversation, tablet
}

func TestCoordinatorOnlyRevocationEmitsOneCompletionEventFromACommitBundle(t *testing.T) {
	ctx := context.Background()
	store, owner, conversation, tablet := newCoordinatorOnlyRevocation(t, ctx)
	result, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 1, IdempotencyKey: "revoke-tablet", Commit: []byte("commit-1"),
		Removed: []MLSDeviceRef{{AccountID: owner.Account.ID, DeviceID: tablet}}, RevocationDeviceID: tablet,
	})
	if err != nil {
		t.Fatal(err)
	}
	var state string
	if err := store.db.QueryRowContext(ctx, `SELECT state FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`, conversation.ID, tablet).Scan(&state); err != nil || state != "completed" {
		t.Fatalf("revocation state = %q, err = %v, want completed", state, err)
	}
	if result.RevocationCompletedEventID == 0 {
		t.Fatal("the bundle result carries no completion event for the HTTP layer to publish")
	}
	if n := completedRevocationEvents(t, ctx, store, conversation.ID, tablet); n != 1 {
		t.Fatalf("completion events after the bundle = %d, want 1", n)
	}
	// The coordinator's later confirmation finds it confirmed already and adds
	// nothing.
	if id, err := store.ConfirmMLSRevocation(ctx, conversation.ID, tablet, owner.Account.ID, owner.Device.ID); err != nil || id != 0 {
		t.Fatalf("late confirm: event %d, err = %v, want none", id, err)
	}
	if n := completedRevocationEvents(t, ctx, store, conversation.ID, tablet); n != 1 {
		t.Fatalf("completion events after the late confirm = %d, want still 1", n)
	}
}

func TestCoordinatorOnlyRevocationEmitsOneCompletionEventFromALegacyCommit(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	const tablet = "dev_owner_tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	message, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Kind: "commit", Payload: []byte("commit"), IdempotencyKey: "legacy-revoke", RevocationDeviceID: tablet,
	})
	if err != nil {
		t.Fatal(err)
	}
	if message.RevocationCompletedEventID == 0 {
		t.Fatal("the message carries no completion event for the HTTP layer to publish")
	}
	if n := completedRevocationEvents(t, ctx, store, conversation.ID, tablet); n != 1 {
		t.Fatalf("completion events = %d, want 1", n)
	}
}

// With several devices to confirm, the one completion event comes with the
// last confirmation and never earlier.
func TestMultiDeviceRevocationEmitsTheCompletionEventAtTheLastConfirmation(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	const tablet = "dev_bob_tablet"
	addTestDevice(t, ctx, store, bob.Account.ID, tablet)
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}, {AccountID: bob.Account.ID, DeviceID: tablet}},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, bob.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	pending, err := store.ListMLSRevocations(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil || len(pending) != 1 {
		t.Fatalf("revocations = %#v, err = %v", pending, err)
	}
	coordinator, other := owner, bob
	if pending[0].CoordinatorDeviceID == bob.Device.ID {
		coordinator, other = bob, owner
	}
	result, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: coordinator.Account.ID, SenderDeviceID: coordinator.Device.ID,
		Epoch: 1, IdempotencyKey: "revoke-tablet", Commit: []byte("commit-1"),
		Removed: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: tablet}}, RevocationDeviceID: tablet,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.RevocationCompletedEventID != 0 || completedRevocationEvents(t, ctx, store, conversation.ID, tablet) != 0 {
		t.Fatal("completion announced while another device still has to confirm")
	}
	id, err := store.ConfirmMLSRevocation(ctx, conversation.ID, tablet, other.Account.ID, other.Device.ID)
	if err != nil || id == 0 {
		t.Fatalf("last confirm: event %d, err = %v, want the completion event", id, err)
	}
	if n := completedRevocationEvents(t, ctx, store, conversation.ID, tablet); n != 1 {
		t.Fatalf("completion events = %d, want 1", n)
	}
	if again, err := store.ConfirmMLSRevocation(ctx, conversation.ID, tablet, other.Account.ID, other.Device.ID); err != nil || again != 0 {
		t.Fatalf("repeated confirm: event %d, err = %v, want none", again, err)
	}
	if n := completedRevocationEvents(t, ctx, store, conversation.ID, tablet); n != 1 {
		t.Fatalf("completion events after a repeated confirm = %d, want 1", n)
	}
}
