package storage

import (
	"context"
	"errors"
	"testing"

	"private-messenger/server/internal/domain"
)

// The devices these tests add have ids that sort before every generated id
// ("dev-" < "dev_"), so the lowest-id rule picks among them predictably.
const (
	coordBob      = "dev-b-bob"
	coordCarol    = "dev-c-carol"
	coordTablet   = "dev-z-carol-tablet"
	coordOwnerNew = "dev-a-owner-new"
)

type rosteredRevocation struct {
	store        *Store
	conversation domain.Conversation
	owner        AccountDevice
	bob          AccountDevice
	carol        AccountDevice
}

// newRosteredRevocation sets up a rostered group of the owner's device,
// coordBob and coordCarol, and Carol's tablet, then revokes the tablet. The
// group is at epoch 1 and coordBob coordinates the revocation.
func newRosteredRevocation(t *testing.T, ctx context.Context) rosteredRevocation {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
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
	addTestDevice(t, ctx, store, bob.Account.ID, coordBob)
	addTestDevice(t, ctx, store, carol.Account.ID, coordCarol)
	addTestDevice(t, ctx, store, carol.Account.ID, coordTablet)
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{
			{AccountID: bob.Account.ID, DeviceID: coordBob},
			{AccountID: carol.Account.ID, DeviceID: coordCarol},
			{AccountID: carol.Account.ID, DeviceID: coordTablet},
		},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, carol.Account.ID, coordTablet); err != nil {
		t.Fatal(err)
	}
	var stored string
	if err := store.db.QueryRowContext(ctx, `SELECT coordinator_device_id FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
		conversation.ID, coordTablet).Scan(&stored); err != nil || stored != coordBob {
		t.Fatalf("stored coordinator = %q, err = %v, want %q", stored, err, coordBob)
	}
	return rosteredRevocation{store: store, conversation: conversation, owner: owner, bob: bob, carol: carol}
}

func (f rosteredRevocation) revocationBundle(ctx context.Context, accountID, deviceID string, epoch int64, key string) error {
	_, err := f.store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: f.conversation.ID, SenderAccountID: accountID, SenderDeviceID: deviceID,
		Epoch: epoch, IdempotencyKey: key, Commit: []byte("commit-" + key),
		Removed:            []MLSDeviceRef{{AccountID: f.carol.Account.ID, DeviceID: coordTablet}},
		RevocationDeviceID: coordTablet,
	})
	return err
}

// listedCoordinator is the tablet revocation's coordinator as the device sees
// it in its revocation list, or "" when the list leaves it out.
func (f rosteredRevocation) listedCoordinator(t *testing.T, ctx context.Context, accountID, deviceID string) string {
	t.Helper()
	items, err := f.store.ListMLSRevocations(ctx, accountID, deviceID)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if item.ConversationID == f.conversation.ID && item.RevokedDeviceID == coordTablet {
			return item.CoordinatorDeviceID
		}
	}
	return ""
}

// While the recorded coordinator can act, it alone may commit the
// revocation (TASK-214).
func TestRevocationCoordinatorStaysWhileItCanCommit(t *testing.T) {
	ctx := context.Background()
	f := newRosteredRevocation(t, ctx)
	if got := f.listedCoordinator(t, ctx, f.carol.Account.ID, coordCarol); got != coordBob {
		t.Fatalf("listed coordinator = %q, want %q", got, coordBob)
	}
	if err := f.revocationBundle(ctx, f.carol.Account.ID, coordCarol, 1, "early"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("commit by a group device that does not coordinate: err = %v, want %v", err, ErrForbidden)
	}
	if err := f.revocationBundle(ctx, f.bob.Account.ID, coordBob, 1, "coordinator"); err != nil {
		t.Fatalf("commit by the coordinator: %v", err)
	}
}

// A revoked coordinator never commits, so the lowest eligible group device
// takes over, even one that joined after the revocation was queued and so has
// nothing to confirm.
func TestRevocationCoordinatorFallsBackWhenTheCoordinatorIsRevoked(t *testing.T) {
	ctx := context.Background()
	f := newRosteredRevocation(t, ctx)
	addTestDevice(t, ctx, f.store, f.owner.Account.ID, coordOwnerNew)
	if _, err := f.store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: f.conversation.ID, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		Epoch: 1, IdempotencyKey: "add-new", Commit: []byte("commit-add"), Welcome: []byte("welcome-add"),
		Added: []MLSDeviceRef{{AccountID: f.owner.Account.ID, DeviceID: coordOwnerNew}},
	}); err != nil {
		t.Fatal(err)
	}
	// The recorded coordinator is still eligible: the newcomer waits.
	if got := f.listedCoordinator(t, ctx, f.owner.Account.ID, coordOwnerNew); got != "" {
		t.Fatalf("a device with nothing to confirm sees the revocation before it coordinates (coordinator %q)", got)
	}
	if _, err := f.store.RevokeDeviceWithSyncEvent(ctx, f.bob.Account.ID, coordBob); err != nil {
		t.Fatal(err)
	}
	if got := f.listedCoordinator(t, ctx, f.owner.Account.ID, coordOwnerNew); got != coordOwnerNew {
		t.Fatalf("new coordinator sees coordinator %q, want itself (%q)", got, coordOwnerNew)
	}
	if got := f.listedCoordinator(t, ctx, f.carol.Account.ID, coordCarol); got != coordOwnerNew {
		t.Fatalf("a confirming device sees coordinator %q, want %q", got, coordOwnerNew)
	}
	if err := f.revocationBundle(ctx, f.carol.Account.ID, coordCarol, 2, "not-coordinator"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("commit by a device that is not the new coordinator: err = %v, want %v", err, ErrForbidden)
	}
	if err := f.revocationBundle(ctx, f.owner.Account.ID, coordOwnerNew, 2, "fallback"); err != nil {
		t.Fatalf("commit by the fallback coordinator: %v", err)
	}
	var state string
	if err := f.store.db.QueryRowContext(ctx, `SELECT state FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?`,
		f.conversation.ID, coordTablet).Scan(&state); err != nil || state == "pending" {
		t.Fatalf("revocation state = %q, err = %v, want past pending", state, err)
	}
}

// A coordinator whose account left the conversation is no longer a member,
// so it may not commit; the lowest remaining member device takes over.
func TestRevocationCoordinatorFallsBackWhenItsAccountLeaves(t *testing.T) {
	ctx := context.Background()
	f := newRosteredRevocation(t, ctx)
	if _, err := f.store.RemoveConversationMember(ctx, f.conversation.ID, f.owner.Account.ID, f.bob.Account.ID); err != nil {
		t.Fatal(err)
	}
	if got := f.listedCoordinator(t, ctx, f.carol.Account.ID, coordCarol); got != coordCarol {
		t.Fatalf("listed coordinator = %q, want %q", got, coordCarol)
	}
	// The departed device is still in the MLS roster but is no member.
	if err := f.revocationBundle(ctx, f.bob.Account.ID, coordBob, 1, "departed"); !errors.Is(err, ErrNotMember) {
		t.Fatalf("commit by the departed coordinator: err = %v, want %v", err, ErrNotMember)
	}
	if err := f.revocationBundle(ctx, f.owner.Account.ID, f.owner.Device.ID, 1, "owner"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("commit by a member that does not coordinate: err = %v, want %v", err, ErrForbidden)
	}
	if err := f.revocationBundle(ctx, f.carol.Account.ID, coordCarol, 1, "fallback"); err != nil {
		t.Fatalf("commit by the fallback coordinator: %v", err)
	}
}

// Groups without a recorded roster commit revocations as plain MLS messages;
// the same fallback applies there.
func TestLegacyRevocationCoordinatorFallsBackWhenItsAccountLeaves(t *testing.T) {
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
	addTestDevice(t, ctx, store, bob.Account.ID, coordBob)
	const tablet = "dev-z-owner-tablet"
	addTestDevice(t, ctx, store, owner.Account.ID, tablet)
	makeLegacyMLSGroup(t, ctx, store, conversation.ID, owner)
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, owner.Account.ID, tablet); err != nil {
		t.Fatal(err)
	}
	commit := func(sender AccountDevice, deviceID, key string) error {
		_, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
			ConversationID: conversation.ID, SenderAccountID: sender.Account.ID, SenderDeviceID: deviceID,
			Kind: "commit", Payload: []byte("commit-" + key), IdempotencyKey: key, RevocationDeviceID: tablet,
		})
		return err
	}
	if err := commit(owner, owner.Device.ID, "early"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("commit before the coordinator left: err = %v, want %v", err, ErrForbidden)
	}
	if _, err := store.RemoveConversationMember(ctx, conversation.ID, owner.Account.ID, bob.Account.ID); err != nil {
		t.Fatal(err)
	}
	if err := commit(bob, coordBob, "departed"); !errors.Is(err, ErrNotMember) {
		t.Fatalf("commit by the departed coordinator: err = %v, want %v", err, ErrNotMember)
	}
	items, err := store.ListMLSRevocations(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil || len(items) != 1 || items[0].CoordinatorDeviceID != owner.Device.ID {
		t.Fatalf("revocations = %#v, err = %v, want the owner's device as coordinator", items, err)
	}
	if err := commit(owner, owner.Device.ID, "fallback"); err != nil {
		t.Fatalf("commit by the fallback coordinator: %v", err)
	}
}
