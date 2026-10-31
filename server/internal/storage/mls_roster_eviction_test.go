package storage

import (
	"context"
	"errors"
	"testing"
)

// C-f50be9e4a731: the server cannot read a commit, so a Removed entry is
// accepted only for a device the server itself wants gone. A group device
// cannot evict an active member's device; a device whose account left the
// conversation is still removed by an ordinary bundle.
func TestCommitBundleRemovesOnlyPendingRemovals(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	carol := registerTestMember(t, ctx, store, invite.Code, "carol")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID,
		MemberAccountIDs: []string{bob.Account.ID, carol.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	const ownerTablet = "dev_owner_tablet_evict"
	addTestDevice(t, ctx, store, owner.Account.ID, ownerTablet)
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{
			{AccountID: bob.Account.ID, DeviceID: bob.Device.ID},
			{AccountID: carol.Account.ID, DeviceID: carol.Device.ID},
			{AccountID: owner.Account.ID, DeviceID: ownerTablet},
		},
	}); err != nil {
		t.Fatal(err)
	}
	active := func(deviceID string) bool {
		t.Helper()
		ok, err := activeMLSDevice(ctx, store.db, conversation.ID, deviceID)
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}

	// Bob tries to evict the owner's devices and Carol's phone.
	for i, victim := range []MLSDeviceRef{
		{AccountID: owner.Account.ID, DeviceID: owner.Device.ID},
		{AccountID: owner.Account.ID, DeviceID: ownerTablet},
		{AccountID: carol.Account.ID, DeviceID: carol.Device.ID},
	} {
		_, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
			ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
			Epoch: 1, IdempotencyKey: "evict-" + victim.DeviceID, Commit: []byte{byte('a' + i)},
			Removed: []MLSDeviceRef{victim},
		})
		if !errors.Is(err, ErrForbidden) {
			t.Fatalf("evicting %s: err = %v, want %v", victim.DeviceID, err, ErrForbidden)
		}
		if !active(victim.DeviceID) {
			t.Fatalf("%s left the roster after a refused eviction", victim.DeviceID)
		}
	}
	// Not even a device of the same account may drop its sibling.
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 1, IdempotencyKey: "drop-sibling", Commit: []byte("sibling"),
		Removed: []MLSDeviceRef{{AccountID: owner.Account.ID, DeviceID: ownerTablet}},
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("dropping a sibling device: err = %v, want %v", err, ErrForbidden)
	}

	// Carol leaves: her phone is now a pending removal, which Bob may commit.
	if _, err := store.RemoveConversationMember(ctx, conversation.ID, owner.Account.ID, carol.Account.ID); err != nil {
		t.Fatal(err)
	}
	changes, err := store.ListMLSPendingChanges(ctx, bob.Account.ID, bob.Device.ID)
	if err != nil || len(changes) != 1 || len(changes[0].Remove) != 1 || changes[0].Remove[0].DeviceID != carol.Device.ID {
		t.Fatalf("pending changes = %#v, err = %v, want carol's phone to remove", changes, err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Epoch: 1, IdempotencyKey: "remove-carol", Commit: []byte("remove-carol"),
		Removed: changes[0].Remove,
	}); err != nil {
		t.Fatalf("removing a departed member's device: %v", err)
	}
	if active(carol.Device.ID) {
		t.Fatal("carol's phone is still on the roster")
	}
}
