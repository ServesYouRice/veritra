package storage

import (
	"context"
	"errors"
	"testing"
)

// seedStaleRevocation writes a pending revocation the way a server queued
// one before revocations were limited to groups the device is in: for a
// conversation whose group did not exist yet, coordinated by coordinator and
// waiting on the given devices.
func seedStaleRevocation(t *testing.T, ctx context.Context, store *Store, conversationID, revokedDeviceID, revokedAccountID, coordinator string, required ...string) {
	t.Helper()
	if _, err := store.db.ExecContext(ctx, `INSERT INTO mls_revocations(conversation_id, revoked_device_id, revoked_account_id,
		coordinator_device_id, state, requested_at) VALUES(?, ?, ?, ?, 'pending', ?)`,
		conversationID, revokedDeviceID, revokedAccountID, coordinator, nowString()); err != nil {
		t.Fatal(err)
	}
	for _, deviceID := range required {
		if _, err := store.db.ExecContext(ctx, `INSERT INTO mls_revocation_required_devices(conversation_id, revoked_device_id, device_id)
			VALUES(?, ?, ?)`, conversationID, revokedDeviceID, deviceID); err != nil {
			t.Fatal(err)
		}
	}
}

func revocationRows(t *testing.T, ctx context.Context, store *Store, conversationID, revokedDeviceID string) (revocations, required int) {
	t.Helper()
	revocations = testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
		conversationID, revokedDeviceID)
	required = testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE conversation_id = ? AND revoked_device_id = ?`,
		conversationID, revokedDeviceID)
	return revocations, required
}

// A conversation whose MLS group was never created (setup failed, or the
// creator's first bundle is still in its outbox) has no leaf to remove. A
// revocation queued there named a coordinator whose client could never
// commit it and failed its sync pass on every try.
func TestRevocationIsNotQueuedForAConversationWithoutAGroup(t *testing.T) {
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
	const tablet = "dev-z-owner-tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	// Account deletion queues for every device of the account, long-revoked
	// ones included.
	const bobTablet = "dev-z-bob-tablet"
	addTestDevice(t, ctx, store, bob.Account.ID, bobTablet)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, bob.Account.ID, bobTablet); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DeleteAccountData(ctx, bob.Account.ID); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM mls_revocations WHERE conversation_id = ?`, conversation.ID); n != 0 {
		t.Fatalf("revocations queued in a conversation without a group = %d, want 0", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'mls.revocation.pending' AND conversation_id = ?`,
		conversation.ID); n != 0 {
		t.Fatalf("pending revocation events = %d, want 0", n)
	}
	for _, device := range []AccountDevice{owner, carol} {
		items, err := store.ListMLSRevocations(ctx, device.Account.ID, device.Device.ID)
		if err != nil || len(items) != 0 {
			t.Fatalf("%s revocations = %#v, err = %v, want none", device.Account.Username, items, err)
		}
	}
}

// A revocation queued before that rule, in a conversation that has no group
// yet, names no coordinator and cannot be committed. Creating the group
// drops it: the revoked device is not in the new roster and never will be.
func TestStaleRevocationHasNoCoordinatorAndGroupCreationDropsIt(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID,
		MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	const tablet = "dev-z-owner-tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	seedStaleRevocation(t, ctx, store, conversation.ID, tablet, owner.Account.ID, bob.Device.ID, owner.Device.ID, bob.Device.ID)

	for _, device := range []AccountDevice{owner, bob} {
		items, err := store.ListMLSRevocations(ctx, device.Account.ID, device.Device.ID)
		if err != nil || len(items) != 1 || items[0].CoordinatorDeviceID != "" {
			t.Fatalf("%s revocations = %#v, err = %v, want one with no coordinator", device.Account.Username, items, err)
		}
	}
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Kind: "commit", Payload: []byte("commit"), IdempotencyKey: "stale-revoke", RevocationDeviceID: tablet,
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("commit for a revocation with no leaf to remove: err = %v, want %v", err, ErrForbidden)
	}

	// Bob creates the group (a member, not the recorded coordinator's peer).
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: owner.Account.ID, DeviceID: owner.Device.ID}},
	}); err != nil {
		t.Fatal(err)
	}
	if revocations, required := revocationRows(t, ctx, store, conversation.ID, tablet); revocations != 0 || required != 0 {
		t.Fatalf("after group creation: %d revocations, %d required devices, want none", revocations, required)
	}
	for _, device := range []AccountDevice{owner, bob} {
		items, err := store.ListMLSRevocations(ctx, device.Account.ID, device.Device.ID)
		if err != nil || len(items) != 0 {
			t.Fatalf("%s revocations = %#v, err = %v, want none", device.Account.Username, items, err)
		}
	}
}

// The creator's own first record (a group with no commit yet) drops a stale
// revocation too.
func TestCreatorRecordWithoutCommitDropsStaleRevocation(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	const tablet = "dev-z-owner-tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	seedStaleRevocation(t, ctx, store, conversation.ID, tablet, owner.Account.ID, owner.Device.ID, owner.Device.ID)
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "creator",
	}); err != nil {
		t.Fatal(err)
	}
	if revocations, required := revocationRows(t, ctx, store, conversation.ID, tablet); revocations != 0 || required != 0 {
		t.Fatalf("after the creator record: %d revocations, %d required devices, want none", revocations, required)
	}
}

// In a rostered group a pending revocation of a device that is not an
// active group device has nothing to commit: it names no coordinator, a
// commit for it is refused, and the group's next commit drops it.
func TestRosteredRevocationOfADeviceOutsideTheRosterIsDropped(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID,
		MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}},
	}); err != nil {
		t.Fatal(err)
	}
	const tablet = "dev-z-owner-tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	seedStaleRevocation(t, ctx, store, conversation.ID, tablet, owner.Account.ID, bob.Device.ID, owner.Device.ID, bob.Device.ID)

	items, err := store.ListMLSRevocations(ctx, bob.Account.ID, bob.Device.ID)
	if err != nil || len(items) != 1 || items[0].CoordinatorDeviceID != "" {
		t.Fatalf("bob's revocations = %#v, err = %v, want one with no coordinator", items, err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Epoch: 1, IdempotencyKey: "stale-revoke", Commit: []byte("commit-stale"), RevocationDeviceID: tablet,
		Removed: []MLSDeviceRef{{AccountID: owner.Account.ID, DeviceID: tablet}},
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("commit for a revocation with no leaf to remove: err = %v, want %v", err, ErrForbidden)
	}
	const laptop = "dev-y-bob-laptop"
	addTestDevice(t, ctx, store, bob.Account.ID, laptop)
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 1, IdempotencyKey: "add-laptop", Commit: []byte("commit-1"), Welcome: []byte("welcome-1"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: laptop}},
	}); err != nil {
		t.Fatal(err)
	}
	if revocations, required := revocationRows(t, ctx, store, conversation.ID, tablet); revocations != 0 || required != 0 {
		t.Fatalf("after the next commit: %d revocations, %d required devices, want none", revocations, required)
	}
}

// A pending revocation that no device can commit any more reports no
// coordinator, not the one recorded when it was queued.
func TestRevocationWithNoEligibleDeviceReportsNoCoordinator(t *testing.T) {
	ctx := context.Background()
	f := newRosteredRevocation(t, ctx)
	// The owner takes Bob's and Carol's phones out of the group, then is
	// revoked itself: Carol's phone still has to confirm, but nobody can
	// commit.
	if _, err := f.store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: f.conversation.ID, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		Epoch: 1, IdempotencyKey: "remove-phones", Commit: []byte("commit-remove"),
		Removed: []MLSDeviceRef{
			{AccountID: f.bob.Account.ID, DeviceID: coordBob},
			{AccountID: f.carol.Account.ID, DeviceID: coordCarol},
		},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.RevokeDeviceWithSyncEvent(ctx, f.owner.Account.ID, f.owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	items, err := f.store.ListMLSRevocations(ctx, f.carol.Account.ID, coordCarol)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, item := range items {
		if item.ConversationID == f.conversation.ID && item.RevokedDeviceID == coordTablet {
			found = true
			if item.State != "pending" || item.CoordinatorDeviceID != "" {
				t.Fatalf("revocation = %#v, want pending with no coordinator", item)
			}
		}
	}
	if !found {
		t.Fatalf("carol's phone no longer sees the revocation it must confirm: %#v", items)
	}
}

// A device that must confirm a revocation and is then revoked, or whose
// account is deleted, never confirms. It stops holding the revocation at
// commit_submitted: the revocation completes, with one completion event.
func TestRevokedOrDeletedConfirmingDeviceReleasesTheRevocation(t *testing.T) {
	for _, tc := range []struct {
		name   string
		remove func(t *testing.T, ctx context.Context, f rosteredRevocation)
	}{
		{"revoked", func(t *testing.T, ctx context.Context, f rosteredRevocation) {
			if _, err := f.store.RevokeDeviceWithSyncEvent(ctx, f.carol.Account.ID, coordCarol); err != nil {
				t.Fatal(err)
			}
		}},
		{"account deleted", func(t *testing.T, ctx context.Context, f rosteredRevocation) {
			if _, err := f.store.DeleteAccountData(ctx, f.carol.Account.ID); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			f := newRosteredRevocation(t, ctx)
			if err := f.revocationBundle(ctx, f.bob.Account.ID, coordBob, 1, "coordinator"); err != nil {
				t.Fatal(err)
			}
			if _, err := f.store.ConfirmMLSRevocation(ctx, f.conversation.ID, coordTablet, f.owner.Account.ID, f.owner.Device.ID); err != nil {
				t.Fatal(err)
			}
			state := func() string {
				var state string
				if err := f.store.db.QueryRowContext(ctx, `SELECT state FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
					f.conversation.ID, coordTablet).Scan(&state); err != nil {
					t.Fatal(err)
				}
				return state
			}
			if got := state(); got != "commit_submitted" {
				t.Fatalf("setup: state = %q, want commit_submitted (Carol's phone has not confirmed)", got)
			}
			tc.remove(t, ctx, f)
			if got := state(); got != "completed" {
				t.Fatalf("state after the confirming device left = %q, want completed", got)
			}
			if n := completedRevocationEvents(t, ctx, f.store, f.conversation.ID, coordTablet); n != 1 {
				t.Fatalf("completion events = %d, want 1", n)
			}
			if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM mls_revocation_required_devices WHERE device_id = ? AND confirmed_at IS NULL`,
				coordCarol); n != 0 {
				t.Fatalf("carol's phone still holds %d revocations", n)
			}
		})
	}
}

// A confirming device revoked before the commit is in no longer holds the
// revocation once the commit arrives.
func TestConfirmingDeviceRevokedBeforeTheCommitDoesNotHoldIt(t *testing.T) {
	ctx := context.Background()
	f := newRosteredRevocation(t, ctx)
	if _, err := f.store.RevokeDeviceWithSyncEvent(ctx, f.carol.Account.ID, coordCarol); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ConfirmMLSRevocation(ctx, f.conversation.ID, coordTablet, f.owner.Account.ID, f.owner.Device.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("confirm before the commit: err = %v, want %v", err, ErrForbidden)
	}
	if err := f.revocationBundle(ctx, f.bob.Account.ID, coordBob, 1, "coordinator"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ConfirmMLSRevocation(ctx, f.conversation.ID, coordTablet, f.owner.Account.ID, f.owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	var state string
	if err := f.store.db.QueryRowContext(ctx, `SELECT state FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
		f.conversation.ID, coordTablet).Scan(&state); err != nil || state != "completed" {
		t.Fatalf("state = %q, err = %v, want completed", state, err)
	}
}
