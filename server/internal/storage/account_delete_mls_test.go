package storage

import (
	"context"
	"errors"
	"testing"
)

// Deleting an account revokes its devices; they must also leave every MLS
// group, or their leaves stay in the rosters of the remaining members for
// good. Account deletion queues the same revocations a device revocation
// does, which the remaining members then commit.
func TestDeleteAccountQueuesMLSRevocationsForItsDevices(t *testing.T) {
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
	rostered, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID,
		MemberAccountIDs: []string{bob.Account.ID, carol.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	// A group without a recorded roster (before card I51) is found through
	// the account's membership.
	legacy, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID,
		MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	const bobTablet = "dev-z-bob-tablet"
	addTestDevice(t, ctx, store, bob.Account.ID, bobTablet)
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: rostered.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{
			{AccountID: bob.Account.ID, DeviceID: bob.Device.ID},
			{AccountID: bob.Account.ID, DeviceID: bobTablet},
			{AccountID: carol.Account.ID, DeviceID: carol.Device.ID},
		},
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := store.DeleteAccountData(ctx, bob.Account.ID); err != nil {
		t.Fatal(err)
	}

	for _, conversationID := range []string{rostered.ID, legacy.ID} {
		for _, deviceID := range []string{bob.Device.ID, bobTablet} {
			var state, coordinator string
			if err := store.db.QueryRowContext(ctx, `SELECT state, coordinator_device_id FROM mls_revocations
				WHERE conversation_id = ? AND revoked_device_id = ?`, conversationID, deviceID).Scan(&state, &coordinator); err != nil {
				t.Fatalf("revocation of %s in %s: %v", deviceID, conversationID, err)
			}
			if state != "pending" || coordinator == bob.Device.ID || coordinator == bobTablet {
				t.Fatalf("revocation of %s in %s: state %q, coordinator %q", deviceID, conversationID, state, coordinator)
			}
			if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'mls.revocation.pending'
				AND conversation_id = ? AND json_extract(payload_json, '$.device_id') = ?`, conversationID, deviceID); n != 1 {
				t.Fatalf("pending events for %s in %s = %d, want 1", deviceID, conversationID, n)
			}
		}
	}
	// No device of the deleted account coordinates or has to confirm.
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE device_id IN (?, ?)`,
		bob.Device.ID, bobTablet); n != 0 {
		t.Fatalf("deleted account's devices must confirm %d revocations, want 0", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocation_required_devices
		WHERE conversation_id = ? AND device_id IN (?, ?)`, rostered.ID, owner.Device.ID, carol.Device.ID); n != 4 {
		t.Fatalf("remaining group devices must confirm %d revocations, want 4 (two devices each)", n)
	}

	// The remaining members see both removals and their coordinator commits
	// them, one epoch each. The reconcile remove list leaves them to the
	// revocation flow, since a plain bundle may not remove them.
	items, err := store.ListMLSRevocations(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	var coordinator string
	removals := 0
	for _, item := range items {
		if item.ConversationID == rostered.ID {
			removals++
			coordinator = item.CoordinatorDeviceID
		}
	}
	if removals != 2 {
		t.Fatalf("owner sees %d removals in the rostered group, want 2: %#v", removals, items)
	}
	changes, err := store.ListMLSPendingChanges(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, change := range changes {
		if change.ConversationID == rostered.ID && len(change.Remove) != 0 {
			t.Fatalf("reconcile lists removals that only a revocation commit may make: %#v", change.Remove)
		}
	}
	sender := owner
	if coordinator == carol.Device.ID {
		sender = carol
	}
	for epoch, deviceID := range []string{bob.Device.ID, bobTablet} {
		if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
			ConversationID: rostered.ID, SenderAccountID: sender.Account.ID, SenderDeviceID: sender.Device.ID,
			Epoch: int64(epoch + 1), IdempotencyKey: "remove-" + deviceID, Commit: []byte("commit-" + deviceID),
			Removed:            []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: deviceID}},
			RevocationDeviceID: deviceID,
		}); err != nil {
			t.Fatalf("revocation commit for %s: %v", deviceID, err)
		}
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM conversation_mls_devices
		WHERE conversation_id = ? AND device_id IN (?, ?) AND removed_after_event_id IS NULL`, rostered.ID, bob.Device.ID, bobTablet); n != 0 {
		t.Fatalf("%d of the deleted account's devices are still in the roster", n)
	}
}

// Revoking a device again queues nothing new: the group keeps its one
// revocation and its one pending event.
func TestRepeatedDeviceRevocationAddsNoSecondPendingEvent(t *testing.T) {
	ctx := context.Background()
	store, owner, conversation, tablet := newCoordinatorOnlyRevocation(t, ctx)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil && !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'mls.revocation.pending'
		AND conversation_id = ? AND json_extract(payload_json, '$.device_id') = ?`, conversation.ID, tablet); n != 1 {
		t.Fatalf("pending events after a repeated revocation = %d, want 1", n)
	}
}
