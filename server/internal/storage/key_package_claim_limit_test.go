package storage

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/config"
)

func seedKeyPackages(t *testing.T, ctx context.Context, store *Store, deviceID string, count int) {
	t.Helper()
	for i := 0; i < count; i++ {
		id := fmt.Sprintf("kp_seed_%s_%03d", deviceID, i)
		if _, err := store.db.ExecContext(ctx, `INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at) VALUES(?, ?, X'02', ?, ?, '2999-01-01T00:00:00Z')`,
			id, deviceID, openMLSCiphersuite, nowString()); err != nil {
			t.Fatal(err)
		}
	}
}

func unclaimedKeyPackages(t *testing.T, ctx context.Context, store *Store, deviceID string) int {
	t.Helper()
	return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ? AND claimed_at IS NULL`, deviceID)
}

// One member cannot drain another account's key packages: past its daily
// allowance on a device a claim is refused, and the device keeps the rest.
func TestConversationKeyPackageClaimsAreCappedPerRequesterAndTarget(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{KeyPackageClaimsPerTarget: 3})
	owner := createTestOwner(t, ctx, store)
	members := registerMembers(t, ctx, store, owner, "bob", "mallory")
	bob, mallory := members[0], members[1]
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: mallory.Account.ID, MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	seedKeyPackages(t, ctx, store, bob.Device.ID, 9)
	if got := unclaimedKeyPackages(t, ctx, store, bob.Device.ID); got != 10 {
		t.Fatalf("setup: bob has %d packages, want 10", got)
	}
	for call := 1; call <= 3; call++ {
		claimed, err := store.ClaimConversationKeyPackages(ctx, conversation.ID, mallory.Account.ID, mallory.Device.ID)
		if err != nil || len(claimed) != 1 {
			t.Fatalf("claim %d: %d packages, err = %v", call, len(claimed), err)
		}
	}
	if _, err := store.ClaimConversationKeyPackages(ctx, conversation.ID, mallory.Account.ID, mallory.Device.ID); !errors.Is(err, ErrKeyPackageClaimLimit) {
		t.Fatalf("claim past the allowance: err = %v, want %v", err, ErrKeyPackageClaimLimit)
	}
	if got := unclaimedKeyPackages(t, ctx, store, bob.Device.ID); got != 7 {
		t.Fatalf("bob has %d packages left, want 7: the refused claim must take none", got)
	}
	if got := rejections(store, admission.KeyPackages); got != 1 {
		t.Fatalf("key package rejections = %d, want 1", got)
	}

	// The allowance is per account: the owner joins and claims bob's device
	// on its own count (and mallory's single package, once).
	if err := store.AddConversationMember(ctx, conversation.ID, owner.Account.ID, "member"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ClaimConversationKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID); err != nil {
		t.Fatalf("another account's first claim: %v", err)
	}
	if got := unclaimedKeyPackages(t, ctx, store, bob.Device.ID); got != 6 {
		t.Fatalf("bob has %d packages left, want 6: the owner claims on its own allowance", got)
	}

	// Claims older than the window stop counting.
	old := formatTime(time.Now().UTC().Add(-KeyPackageClaimWindow - time.Hour))
	if _, err := store.db.ExecContext(ctx, `UPDATE device_key_packages SET claimed_at = ? WHERE device_id = ? AND claimed_by_device_id = ?`, old, bob.Device.ID, mallory.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ClaimConversationKeyPackages(ctx, conversation.ID, mallory.Account.ID, mallory.Device.ID); err != nil {
		t.Fatalf("claim after the window passed: %v", err)
	}
}

func TestKeyPackageClaimAllowanceCountsTheWholeAccountAndSparesItsOwnDevices(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{KeyPackageClaimsPerTarget: 3})
	owner := createTestOwner(t, ctx, store)
	members := registerMembers(t, ctx, store, owner, "bob", "mallory")
	bob, mallory := members[0], members[1]
	addTestDevice(t, ctx, store, mallory.Account.ID, "dev_mallory_tablet")
	seedKeyPackages(t, ctx, store, bob.Device.ID, 8)
	seedKeyPackages(t, ctx, store, "dev_mallory_tablet", 8)
	claim := func(target, byDevice string, count int) {
		t.Helper()
		for i := 0; i < count; i++ {
			result, err := store.db.ExecContext(ctx, `UPDATE device_key_packages SET claimed_at = ?, claimed_by_device_id = ? WHERE id = (SELECT id FROM device_key_packages WHERE device_id = ? AND claimed_at IS NULL LIMIT 1)`, nowString(), byDevice, target)
			if err != nil {
				t.Fatal(err)
			}
			if n, _ := result.RowsAffected(); n != 1 {
				t.Fatal("no package left to claim")
			}
		}
	}
	allowed := func(target, targetAccount string) bool {
		t.Helper()
		ok, err := store.keyPackageClaimAllowed(ctx, store.db, target, targetAccount, mallory.Account.ID, time.Now().UTC())
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	// Two claims by mallory's phone and one by her tablet are three by one
	// account.
	claim(bob.Device.ID, mallory.Device.ID, 2)
	if !allowed(bob.Device.ID, bob.Account.ID) {
		t.Fatal("two claims of three were refused")
	}
	claim(bob.Device.ID, "dev_mallory_tablet", 1)
	if allowed(bob.Device.ID, bob.Account.ID) {
		t.Fatal("the account's claims from its two devices were not added up")
	}
	// Another account's claims are not hers.
	if _, err := store.db.ExecContext(ctx, `UPDATE device_key_packages SET claimed_by_device_id = ? WHERE device_id = ?`, owner.Device.ID, bob.Device.ID); err != nil {
		t.Fatal(err)
	}
	if !allowed(bob.Device.ID, bob.Account.ID) {
		t.Fatal("another account's claims counted against mallory")
	}
	// Her own devices are exempt: nothing is taken from anyone else.
	claim("dev_mallory_tablet", mallory.Device.ID, 6)
	if !allowed("dev_mallory_tablet", mallory.Account.ID) {
		t.Fatal("an account was limited in claiming its own device's packages")
	}
}

// Adding devices to an existing group skips a device over its allowance, as
// it skips one with no package left.
func TestDeviceKeyPackageClaimsSkipADeviceOverItsAllowance(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	f.store.limits.KeyPackageClaimsPerTarget = 2
	f.guestDevices("target", 2, 0)
	seedKeyPackages(t, ctx, f.store, "target_0000", 5)
	group := f.group()
	claim := func() int {
		t.Helper()
		packages, err := f.store.ClaimDeviceKeyPackages(ctx, group.ID, f.owner.Account.ID, f.owner.Device.ID, []string{"target_0000", "target_0001"})
		if err != nil {
			t.Fatal(err)
		}
		return len(packages)
	}
	// target_0001 has one package, target_0000 has six.
	if got := claim(); got != 2 {
		t.Fatalf("first claim returned %d packages, want one from each device", got)
	}
	if got := claim(); got != 1 {
		t.Fatalf("second claim returned %d packages, want only target_0000's (target_0001 is empty)", got)
	}
	if got := claim(); got != 0 {
		t.Fatalf("third claim returned %d packages, want none: target_0000 is over its allowance", got)
	}
	if got := unclaimedKeyPackages(t, ctx, f.store, "target_0000"); got != 4 {
		t.Fatalf("target_0000 has %d packages left, want 4", got)
	}
	if got := rejections(f.store, admission.KeyPackages); got < 1 {
		t.Fatalf("key package rejections = %d, want the skipped claim counted", got)
	}
}
