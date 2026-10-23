package storage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

func newLimitedStore(t *testing.T, limits config.Limits) *Store {
	t.Helper()
	dir := t.TempDir()
	store, err := Open(context.Background(), config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "Test Messenger", Limits: limits,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.Migrate(context.Background(), migrations.FS); err != nil {
		t.Fatal(err)
	}
	return store
}

func rejections(store *Store, limit string) int64 {
	var n int64
	store.AdmissionCounters().Each(func(name string, count int64) {
		if name == limit {
			n = count
		}
	})
	return n
}

func registerMembers(t *testing.T, ctx context.Context, store *Store, owner AccountDevice, names ...string) []AccountDevice {
	t.Helper()
	invite, err := store.CreateInvite(ctx, owner.Account.ID, len(names), nil)
	if err != nil {
		t.Fatal(err)
	}
	members := make([]AccountDevice, 0, len(names))
	for _, name := range names {
		members = append(members, registerTestMember(t, ctx, store, invite.Code, name))
	}
	return members
}

func claimLink(t *testing.T, ctx context.Context, store *Store, link domain.DeviceLink, name string) []byte {
	t.Helper()
	if _, err := store.ReserveDeviceLinkEnrollment(ctx, link.Code); err != nil {
		t.Fatal(err)
	}
	_, claimTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	transcript := bytes.Repeat([]byte{byte(len(name))}, 32)
	if _, err := store.ClaimDeviceLink(ctx, link.Code, name, []byte(name+"-key-package"), bytes.Repeat([]byte{2}, 32), transcript, claimTokenHash, auth.HashToken(name+"-secret")); err != nil {
		t.Fatal(err)
	}
	return transcript
}

func TestDeviceLimitHoldsInTheApprovingTransaction(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{DevicesPerAccount: 2})
	owner := createTestOwner(t, ctx, store)
	link, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	transcript := claimLink(t, ctx, store, link, "Tablet")
	// Another device appears between link creation and approval.
	if _, err := store.db.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_extra', ?, 'Laptop', x'00', ?)`, owner.Account.ID, nowString()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, transcript); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("approval past the device limit: %v", err)
	}
	devices, err := countRows(ctx, store.db, `SELECT COUNT(*) FROM devices WHERE account_id = ?`, owner.Account.ID)
	if err != nil || devices != 2 {
		t.Fatalf("devices after refused approval = %d (%v), want 2", devices, err)
	}
	if _, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("link creation at the device limit: %v", err)
	}
	// Removing a device makes room again.
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET revoked_at = ? WHERE id = 'dev_extra'`, nowString()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, transcript); err != nil {
		t.Fatalf("approval after revoking a device: %v", err)
	}
	if got := rejections(store, admission.Devices); got != 2 {
		t.Fatalf("device rejections = %d, want 2", got)
	}
}

func TestPendingDeviceLinksAreBounded(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{})
	owner := createTestOwner(t, ctx, store)
	var first domain.DeviceLink
	for i := 0; i < config.PendingDeviceLinksPerAccount; i++ {
		link, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			first = link
		}
	}
	if _, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute); !errors.Is(err, ErrDeviceLinkLimit) {
		t.Fatalf("fourth open link: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE device_links SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Minute)), first.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute); err != nil {
		t.Fatalf("link after one expired: %v", err)
	}
}

func TestConversationLimitsNeverRevealAnotherAccount(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{ConversationsPerAccount: 10, ConversationMembers: 3})
	owner := createTestOwner(t, ctx, store)
	members := registerMembers(t, ctx, store, owner, "alice", "bob", "carol")
	alice, bob, carol := members[0], members[1], members[2]
	group := func(creator AccountDevice, others ...AccountDevice) (domain.Conversation, error) {
		ids := make([]string, 0, len(others))
		for _, other := range others {
			ids = append(ids, other.Account.ID)
		}
		return store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: creator.Account.ID, MemberAccountIDs: ids})
	}

	// Member limit: the request's own size, then an add to a full group.
	if _, err := group(owner, alice, bob, carol); !errors.Is(err, ErrConversationMemberLimit) {
		t.Fatalf("four-member group with a limit of 3: %v", err)
	}
	full, err := group(owner, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ManageConversationMember(ctx, full.ID, owner.Account.ID, carol.Account.ID, domain.RoleMember); !errors.Is(err, ErrConversationMemberLimit) {
		t.Fatalf("add to a full group: %v", err)
	}

	// Alice fills her own conversation limit (she is already in one).
	for i := 0; i < 9; i++ {
		if _, err := group(alice); err != nil {
			t.Fatalf("alice's conversation %d: %v", i+2, err)
		}
	}
	if _, err := group(alice); !errors.Is(err, ErrConversationLimit) {
		t.Fatalf("alice past her own limit: %v", err)
	}
	// Bob adding Alice gets the same error a block would give.
	_, createErr := group(bob, alice)
	bobsGroup, err := group(bob)
	if err != nil {
		t.Fatal(err)
	}
	_, addErr := store.ManageConversationMember(ctx, bobsGroup.ID, bob.Account.ID, alice.Account.ID, domain.RoleMember)
	if _, err := store.db.ExecContext(ctx, `INSERT INTO account_blocks(blocker_account_id, blocked_account_id, created_at) VALUES(?, ?, ?)`, carol.Account.ID, bob.Account.ID, nowString()); err != nil {
		t.Fatal(err)
	}
	_, blockedErr := store.ManageConversationMember(ctx, bobsGroup.ID, bob.Account.ID, carol.Account.ID, domain.RoleMember)
	for name, err := range map[string]error{"create": createErr, "add": addErr} {
		if err != ErrForbidden || err != blockedErr {
			t.Fatalf("%s with a full third party = %v, a block gives %v", name, err, blockedErr)
		}
	}
	// An existing DM is returned, not refused, even at the limit.
	dm, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 8; i++ { // full group + DM + 8 = 10
		if _, err := group(owner); err != nil {
			t.Fatalf("owner conversation: %v", err)
		}
	}
	if _, err := group(owner); !errors.Is(err, ErrConversationLimit) {
		t.Fatalf("owner past the limit: %v", err)
	}
	again, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil || again.ID != dm.ID {
		t.Fatalf("existing DM at the limit: %v %s", err, again.ID)
	}
	if rejections(store, admission.Members) != 2 || rejections(store, admission.Conversations) != 4 {
		t.Fatalf("rejections members=%d conversations=%d", rejections(store, admission.Members), rejections(store, admission.Conversations))
	}
}

// Concurrent writes for one free slot: the count and the insert share one
// writer transaction, so exactly one wins.
func TestConversationLimitIsTransactionalUnderConcurrency(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{ConversationsPerAccount: 10})
	owner := createTestOwner(t, ctx, store)
	for i := 0; i < 9; i++ {
		if _, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID}); err != nil {
			t.Fatal(err)
		}
	}
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() {
			_, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
			results <- err
		}()
	}
	won := 0
	for i := 0; i < 8; i++ {
		switch err := <-results; {
		case err == nil:
			won++
		case !errors.Is(err, ErrConversationLimit):
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if won != 1 {
		t.Fatalf("%d writers took the last slot", won)
	}
}

func TestCommunityMemberAddNeedsRoomInEveryChannel(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{ConversationMembers: 3})
	owner := createTestOwner(t, ctx, store)
	members := registerMembers(t, ctx, store, owner, "alice", "bob", "carol")
	community, err := store.CreateCommunity(ctx, "Club", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateChannelWithConversation(ctx, community.ID, "general", "", owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	for _, member := range members[:2] {
		if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, member.Account.ID, domain.RoleMember); err != nil {
			t.Fatalf("add %s: %v", member.Account.Username, err)
		}
	}
	if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, members[2].Account.ID, domain.RoleMember); !errors.Is(err, ErrConversationMemberLimit) {
		t.Fatalf("fourth community member: %v", err)
	}
	// A role change of an existing member is not an addition.
	if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, members[0].Account.ID, domain.RoleModerator); err != nil {
		t.Fatalf("role change in a full community: %v", err)
	}
}

func TestAccountBlobCountIsBounded(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{AccountBlobs: 100})
	owner := createTestOwner(t, ctx, store)
	for i := 0; i < 99; i++ {
		if _, err := store.db.ExecContext(ctx, `INSERT INTO attachment_envelopes(id, owner_account_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at) VALUES(?, ?, ?, ?, 1, '{}', ?)`,
			fmt.Sprintf("att_%d", i), owner.Account.ID, fmt.Sprintf("blob_%d", i), fmt.Sprintf("%064x", i), nowString()); err != nil {
			t.Fatal(err)
		}
	}
	create := func(i int) error {
		_, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{OwnerAccountID: owner.Account.ID,
			StorageKey: fmt.Sprintf("blob_new_%d", i), CiphertextSHA256: fmt.Sprintf("%064x", 1000+i), SizeBytes: 1})
		return err
	}
	if err := create(0); err != nil {
		t.Fatalf("100th blob: %v", err)
	}
	if err := create(1); !errors.Is(err, ErrStorageQuota) {
		t.Fatalf("101st blob: %v", err)
	}
	if got := rejections(store, admission.Blobs); got != 1 {
		t.Fatalf("blob rejections = %d", got)
	}
}
