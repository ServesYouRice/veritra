package storage

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"private-messenger/server/internal/domain"
)

type savedEnvelope struct{ SyncEventID int64 }

func saveTestEnvelope(t *testing.T, ctx context.Context, store *Store, conversationID string, sender AccountDevice, key string, metadata ...string) savedEnvelope {
	t.Helper()
	envelope := domain.MessageEnvelope{
		ConversationID: conversationID, SenderAccountID: sender.Account.ID, SenderDeviceID: sender.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("ciphertext"), CryptoProtocol: "mls10-openmls-v1",
	}
	if len(metadata) > 0 {
		envelope.CryptoMetadata = json.RawMessage(metadata[0])
	}
	_, _, eventID, err := store.SaveMessageEnvelopeWithSyncEvent(ctx, envelope)
	if err != nil {
		t.Fatalf("save envelope: %v", err)
	}
	return savedEnvelope{SyncEventID: eventID}
}

// addTestDevice links a second device to an account for roster tests.
func addTestDevice(t *testing.T, ctx context.Context, store *Store, accountID, deviceID string) {
	t.Helper()
	now := nowString()
	if _, err := store.db.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at)
		VALUES(?, ?, 'second', X'01', NULL, 'hash', ?)`, deviceID, accountID, now); err != nil {
		t.Fatalf("add device: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at)
		VALUES(?, ?, X'02', ?, ?, '2999-01-01T00:00:00Z')`, "kp_"+deviceID, deviceID, openMLSCiphersuite, now); err != nil {
		t.Fatalf("add key package: %v", err)
	}
}

func syncEventIDs(t *testing.T, ctx context.Context, store *Store, accountID, deviceID string) map[int64]string {
	t.Helper()
	events, err := store.ListSyncEvents(ctx, accountID, deviceID, 0, 200)
	if err != nil {
		t.Fatalf("list sync events: %v", err)
	}
	result := map[int64]string{}
	for _, event := range events {
		result[event.ID] = event.Type
	}
	return result
}

func TestMLSCommitBundlesOrderByEpochAndTrackTheRoster(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 3, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	carol := registerTestMember(t, ctx, store, invite.Code, "carol")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	// An envelope before the group exists is visible to members as before.
	saveTestEnvelope(t, ctx, store, conversation.ID, owner, "before-group")

	// Genesis: the creator adds Bob in the first commit, on epoch 0.
	genesis, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}},
	})
	if err != nil || genesis.Epoch != 1 || genesis.Commit == nil || len(genesis.Welcomes) != 1 {
		t.Fatalf("genesis=%#v err=%v", genesis, err)
	}
	retry, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}},
	})
	if err != nil || !retry.Duplicate || retry.Commit.ID != genesis.Commit.ID {
		t.Fatalf("idempotent retry=%#v err=%v", retry, err)
	}

	// The old single-message route is closed for rostered groups.
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Kind: "commit", Payload: []byte("stray"), IdempotencyKey: "stray",
	}); !errors.Is(err, ErrMLSBundleRequired) {
		t.Fatalf("stray commit err=%v", err)
	}

	// Bob's second device joins the account and the conversation.
	addTestDevice(t, ctx, store, bob.Account.ID, "dev_bob_tablet")
	if err := store.AddConversationMember(ctx, conversation.ID, carol.Account.ID, "member"); err != nil {
		t.Fatal(err)
	}
	pending, err := store.ListMLSPendingChanges(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil || len(pending) != 1 || pending[0].Epoch != 1 || len(pending[0].Add) != 2 {
		t.Fatalf("pending=%#v err=%v", pending, err)
	}
	// A device outside the group sees no pending work for it.
	if outside, err := store.ListMLSPendingChanges(ctx, carol.Account.ID, carol.Device.ID); err != nil || len(outside) != 0 {
		t.Fatalf("outside pending=%#v err=%v", outside, err)
	}

	// Per-device claim: only the listed devices, and a device with no
	// package left is skipped instead of failing the claim.
	claimed, err := store.ClaimDeviceKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID,
		[]string{"dev_bob_tablet", carol.Device.ID})
	if err != nil || len(claimed) != 2 {
		t.Fatalf("claim=%#v err=%v", claimed, err)
	}
	again, err := store.ClaimDeviceKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID, []string{"dev_bob_tablet"})
	if err != nil || len(again) != 0 {
		t.Fatalf("exhausted claim=%#v err=%v", again, err)
	}
	if _, err := store.ClaimDeviceKeyPackages(ctx, conversation.ID, carol.Account.ID, carol.Device.ID, []string{"dev_bob_tablet"}); !errors.Is(err, ErrMLSNotInGroup) {
		t.Fatalf("non-group claim err=%v", err)
	}

	// Owner and Bob race on epoch 1: the second commit is refused.
	added := []MLSDeviceRef{
		{AccountID: bob.Account.ID, DeviceID: "dev_bob_tablet"},
		{AccountID: carol.Account.ID, DeviceID: carol.Device.ID},
	}
	first, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 1, IdempotencyKey: "add-two", Commit: []byte("commit-1"), Welcome: []byte("welcome-1"), Added: added,
	})
	if err != nil || first.Epoch != 2 || len(first.Welcomes) != 2 {
		t.Fatalf("first=%#v err=%v", first, err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Epoch: 1, IdempotencyKey: "bob-add", Commit: []byte("commit-1b"), Welcome: []byte("welcome-1b"), Added: added,
	}); !errors.Is(err, ErrMLSEpochConflict) {
		t.Fatalf("losing commit err=%v", err)
	}
	if epoch, ok, err := store.MLSGroupEpoch(ctx, conversation.ID); err != nil || !ok || epoch != 2 {
		t.Fatalf("epoch=%d ok=%v err=%v", epoch, ok, err)
	}

	// Join cursor: the tablet sees its Welcome and later events only; Bob's
	// phone does not see the tablet's Welcome.
	after := saveTestEnvelope(t, ctx, store, conversation.ID, owner, "after-join", `{"mls_epoch":2}`)
	// Bob's phone sends in epoch 1 before it has seen the commit; the
	// message is stored after the commit but the tablet cannot read it.
	late := saveTestEnvelope(t, ctx, store, conversation.ID, bob, "late-epoch", `{"mls_epoch":1}`)
	tablet := syncEventIDs(t, ctx, store, bob.Account.ID, "dev_bob_tablet")
	phone := syncEventIDs(t, ctx, store, bob.Account.ID, bob.Device.ID)
	tabletWelcome := first.Welcomes[0]
	if tabletWelcome.RecipientDeviceID != "dev_bob_tablet" {
		tabletWelcome = first.Welcomes[1]
	}
	if _, ok := tablet[tabletWelcome.SyncEventID]; !ok {
		t.Fatalf("tablet misses its welcome: %#v", tablet)
	}
	if _, ok := phone[tabletWelcome.SyncEventID]; ok {
		t.Fatal("another device of the account sees the welcome")
	}
	if _, ok := tablet[first.Commit.SyncEventID]; ok {
		t.Fatal("the joining device sees the commit that added it")
	}
	if _, ok := tablet[genesis.Commit.SyncEventID]; ok {
		t.Fatal("the joining device sees an earlier commit")
	}
	if _, ok := tablet[after.SyncEventID]; !ok {
		t.Fatal("the joining device misses a later message")
	}
	if _, ok := tablet[late.SyncEventID]; ok {
		t.Fatal("the joining device sees a message from before its epoch")
	}
	if _, ok := syncEventIDs(t, ctx, store, owner.Account.ID, owner.Device.ID)[late.SyncEventID]; !ok {
		t.Fatal("a member who can read the late message misses it")
	}
	if _, ok := phone[first.Commit.SyncEventID]; !ok {
		t.Fatal("a group device misses a commit")
	}
	if _, err := store.MLSMessage(ctx, genesis.Commit.ID, bob.Account.ID, "dev_bob_tablet"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("tablet fetches an earlier commit: %v", err)
	}
	if _, err := store.MLSMessage(ctx, tabletWelcome.ID, bob.Account.ID, bob.Device.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("phone fetches the tablet welcome: %v", err)
	}

	// Carol leaves: the remaining group devices are asked to remove her.
	if _, err := store.RemoveConversationMember(ctx, conversation.ID, carol.Account.ID, carol.Account.ID); err != nil {
		t.Fatal(err)
	}
	pending, err = store.ListMLSPendingChanges(ctx, bob.Account.ID, bob.Device.ID)
	if err != nil || len(pending) != 1 || len(pending[0].Remove) != 1 || pending[0].Remove[0].DeviceID != carol.Device.ID || len(pending[0].Add) != 0 {
		t.Fatalf("removal pending=%#v err=%v", pending, err)
	}
	removal, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Epoch: 2, IdempotencyKey: "remove-carol", Commit: []byte("commit-2"),
		Removed: []MLSDeviceRef{{AccountID: carol.Account.ID, DeviceID: carol.Device.ID}},
	})
	if err != nil || removal.Epoch != 3 {
		t.Fatalf("removal=%#v err=%v", removal, err)
	}
	if pending, err := store.ListMLSPendingChanges(ctx, bob.Account.ID, bob.Device.ID); err != nil || len(pending) != 0 {
		t.Fatalf("pending after removal=%#v err=%v", pending, err)
	}

	// Revoking the tablet makes a group device coordinate its removal.
	if _, err := store.RevokeDeviceWithSyncEvent(ctx, bob.Account.ID, "dev_bob_tablet"); err != nil {
		t.Fatal(err)
	}
	revocations, err := store.ListMLSRevocations(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	var coordinator string
	for _, item := range revocations {
		if item.ConversationID == conversation.ID && item.RevokedDeviceID == "dev_bob_tablet" {
			coordinator = item.CoordinatorDeviceID
		}
	}
	if coordinator != bob.Device.ID && coordinator != owner.Device.ID {
		t.Fatalf("revocation coordinator=%q", coordinator)
	}
}

func TestMLSCommitBundleRejectsOutsidersAndLegacyGroups(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	// A note-to-self style genesis: no commit, only the creator record.
	if result, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis",
	}); err != nil || result.Epoch != 0 {
		t.Fatalf("empty genesis=%#v err=%v", result, err)
	}
	// Bob is a member but not in the group yet: he cannot commit.
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Epoch: 0, IdempotencyKey: "bob", Commit: []byte("c"),
		Removed: []MLSDeviceRef{{AccountID: owner.Account.ID, DeviceID: owner.Device.ID}},
	}); !errors.Is(err, ErrMLSNotInGroup) {
		t.Fatalf("outsider commit err=%v", err)
	}
	// Adding a device that is not a member's is refused.
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "stranger", Commit: []byte("c"), Welcome: []byte("w"),
		Added: []MLSDeviceRef{{AccountID: "acct_x", DeviceID: "dev_x"}},
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("stranger add err=%v", err)
	}
	// Malformed bundles.
	for name, input := range map[string]MLSCommitBundleInput{
		"welcome without add": {Epoch: 0, IdempotencyKey: "a", Commit: []byte("c"), Welcome: []byte("w"),
			Removed: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}}},
		"commit without change": {Epoch: 0, IdempotencyKey: "b", Commit: []byte("c")},
		"self removal": {Epoch: 0, IdempotencyKey: "c", Commit: []byte("c"),
			Removed: []MLSDeviceRef{{AccountID: owner.Account.ID, DeviceID: owner.Device.ID}}},
	} {
		input.ConversationID = conversation.ID
		input.SenderAccountID = owner.Account.ID
		input.SenderDeviceID = owner.Device.ID
		if _, err := store.CreateMLSCommitBundle(ctx, input); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("%s err=%v", name, err)
		}
	}

	// A group that already has MLS messages but no roster is legacy.
	legacy, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: legacy.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		RecipientDeviceID: bob.Device.ID, Kind: "welcome", Payload: []byte("w"), IdempotencyKey: "legacy-welcome",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: legacy.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "late-genesis",
	}); !errors.Is(err, ErrMLSGroupLegacy) {
		t.Fatalf("legacy genesis err=%v", err)
	}
	// Legacy groups keep delivering their events unfiltered.
	events := syncEventIDs(t, ctx, store, bob.Account.ID, bob.Device.ID)
	if len(events) == 0 {
		t.Fatal("legacy events are hidden")
	}
}
