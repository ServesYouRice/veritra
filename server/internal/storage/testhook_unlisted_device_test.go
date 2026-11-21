//go:build veritra_testhooks

package storage

import (
	"bytes"
	"context"
	"testing"

	"private-messenger/server/internal/mlswire/mlswiretest"
)

// The L1-5 test hook makes this server offer a device no signed version
// names: pending adds and claims list it, the signed statements stay as
// they were. Clients must refuse it (mobile/test/l1_live_e2e_test.dart).
func TestInsertUnlistedDeviceForTestOffersTheGhost(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	group := f.group()
	registered := f.guestRegisteredDevice()
	f.seedHead(f.guest, registered)
	var before []byte
	if err := f.store.db.QueryRowContext(ctx, `SELECT statement FROM device_list_versions WHERE account_id = ?`, f.guest).Scan(&before); err != nil {
		t.Fatal(err)
	}
	ghostKey := bytes.Repeat([]byte{0x77}, 32)
	if err := f.store.InsertUnlistedDeviceForTest(ctx, f.guest, "dev_ghost", mlswiretest.KeyPackageWithSignatureKey(ghostKey)); err != nil {
		t.Fatal(err)
	}
	if got := addIDs(f.list(), group.ID); !contains(got, "dev_ghost") {
		t.Fatalf("the ghost is not offered: %v", got)
	}
	claimed, err := f.store.ClaimDeviceKeyPackages(ctx, group.ID, f.owner.Account.ID, f.owner.Device.ID, []string{"dev_ghost"})
	if err != nil || len(claimed) != 1 {
		t.Fatalf("claim of the ghost: %v, %d packages", err, len(claimed))
	}
	var after []byte
	if err := f.store.db.QueryRowContext(ctx, `SELECT statement FROM device_list_versions WHERE account_id = ?`, f.guest).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("the hook changed the signed statement")
	}
	// No signed list: nothing to lie about.
	if err := f.store.InsertUnlistedDeviceForTest(ctx, f.owner.Account.ID, "dev_ghost2", mlswiretest.KeyPackageWithSignatureKey(bytes.Repeat([]byte{0x78}, 32))); err == nil {
		t.Fatal("inserted a ghost for an account with no list")
	}
}
