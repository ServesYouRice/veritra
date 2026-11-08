package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/mlswire"
	"private-messenger/server/internal/mlswire/mlswiretest"
)

// The honest-server gates of L1-2 (docs/designs/L1-approved-device-list.md,
// "Honest-server gates"): once an account has a device list, pending changes,
// key-package claims and commit bundles name only devices on its head. Clients
// do not rely on this. An account with no list stays exactly as before.

// seedHead gives account a one-version list whose head names only listed. The
// statement bytes are opaque here: the gates read the derived table.
func (f *pendingFixture) seedHead(accountID string, listed ...string) {
	f.t.Helper()
	f.exec(`INSERT INTO device_list_versions(account_id, version, list_hash, statement, change, signer_device_id, created_at) VALUES(?, 1, ?, X'01', 6, ?, ?)`,
		accountID, bytes.Repeat([]byte{1}, 32), listed[0], nowString())
	for index, deviceID := range listed {
		key := bytes.Repeat([]byte{byte(10 + index)}, 32)
		f.exec(`INSERT INTO device_list_devices(account_id, device_id, signing_key, added_version) VALUES(?, ?, ?, 1)`,
			accountID, deviceID, key)
		// A key package carrying the listed key (the L1 key-package gate,
		// Q-1); the fixtures' opaque packages fail that gate.
		f.exec(`INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at) VALUES(?, ?, ?, ?, ?, '2999-01-01T00:00:00Z')`,
			"kp_listed_"+deviceID, deviceID, mlswiretest.KeyPackageWithSignatureKey(key), openMLSCiphersuite, nowString())
	}
}

func addIDs(changes []MLSPendingChange, conversationID string) []string {
	for _, change := range changes {
		if change.ConversationID == conversationID {
			ids := make([]string, 0, len(change.Add))
			for _, ref := range change.Add {
				ids = append(ids, ref.DeviceID)
			}
			return ids
		}
	}
	return nil
}

func contains(ids []string, id string) bool {
	for _, got := range ids {
		if got == id {
			return true
		}
	}
	return false
}

func TestPendingChangesOfferOnlyDevicesOnTheHead(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	group := f.group()
	f.guestDevices("extra", 2, 0) // two more devices of the guest, with key packages
	registered := f.guestRegisteredDevice()

	before := addIDs(f.list(), group.ID)
	if len(before) != 3 {
		t.Fatalf("no list: %d devices offered, want all 3", len(before))
	}
	f.seedHead(f.guest, registered)
	after := addIDs(f.list(), group.ID)
	if len(after) != 1 || after[0] != registered {
		t.Fatalf("with a list: offered %v, want only %s", after, registered)
	}
	// A removed device is not on the head.
	f.exec(`UPDATE device_list_devices SET removed_version = 2 WHERE device_id = ?`, registered)
	if got := addIDs(f.list(), group.ID); len(got) != 0 {
		t.Fatalf("a removed device is offered: %v", got)
	}
}

func TestClaimsAndBundlesRefuseDevicesOffTheHead(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	group := f.group()
	f.guestDevices("extra", 1, 0)
	registered := f.guestRegisteredDevice()
	f.seedHead(f.guest, registered)

	if _, err := f.store.ClaimDeviceKeyPackages(ctx, group.ID, f.owner.Account.ID, f.owner.Device.ID, []string{"extra_0000"}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("claim of a device off the head err=%v, want ErrForbidden", err)
	}
	if n, _ := countRows(ctx, f.store.db, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = 'extra_0000' AND claimed_at IS NOT NULL`); n != 0 {
		t.Fatal("a key package of a device off the head was claimed")
	}
	if _, err := f.store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: group.ID, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		Epoch: 1, IdempotencyKey: "off-head", Commit: []byte("c"), Welcome: []byte("w"),
		Added: []MLSDeviceRef{{AccountID: f.guest, DeviceID: "extra_0000"}},
	}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("a bundle adding a device off the head err=%v, want ErrForbidden", err)
	}
	// The listed device is claimed and added as before.
	claimed, err := f.store.ClaimDeviceKeyPackages(ctx, group.ID, f.owner.Account.ID, f.owner.Device.ID, []string{registered})
	if err != nil || len(claimed) != 1 {
		t.Fatalf("claim of a listed device: %v %v", claimed, err)
	}
	if _, err := f.store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: group.ID, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		Epoch: 1, IdempotencyKey: "on-head", Commit: []byte("c"), Welcome: []byte("w"),
		Added: []MLSDeviceRef{{AccountID: f.guest, DeviceID: registered}},
	}); err != nil {
		t.Fatalf("a bundle adding a listed device: %v", err)
	}
}

func TestConversationKeyPackageClaimNamesOnlyListedDevices(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	conversation, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID, MemberAccountIDs: []string{f.guest}})
	if err != nil {
		t.Fatal(err)
	}
	f.guestDevices("extra", 1, 0)
	registered := f.guestRegisteredDevice()
	devices := func() []string {
		packages, err := f.store.ClaimConversationKeyPackages(ctx, conversation.ID, f.owner.Account.ID, f.owner.Device.ID)
		if err != nil {
			t.Fatal(err)
		}
		ids := make([]string, 0, len(packages))
		for _, item := range packages {
			ids = append(ids, item.DeviceID)
		}
		return ids
	}
	if got := devices(); len(got) != 2 || !contains(got, "extra_0000") || !contains(got, registered) {
		t.Fatalf("no list: claimed %v", got)
	}
	// The first claim used each device's key package; give the listed one another.
	f.exec(`INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at) VALUES('kp_again', ?, X'02', ?, ?, '2999-01-01T00:00:00Z')`,
		registered, openMLSCiphersuite, nowString())
	f.seedHead(f.guest, registered)
	if got := devices(); len(got) != 1 || got[0] != registered {
		t.Fatalf("with a list: claimed %v, want only %s", got, registered)
	}
}

func (f *pendingFixture) guestRegisteredDevice() string {
	f.t.Helper()
	var id string
	if err := f.store.db.QueryRowContext(f.ctx, `SELECT id FROM devices WHERE account_id = ? ORDER BY created_at, id LIMIT 1`, f.guest).Scan(&id); err != nil {
		f.t.Fatal(err)
	}
	return id
}

// The L1 key-package gate (bug-hunt Q-1, owner 2026-11-08): for an account
// with a list, a published key package must carry the key the head names for
// its device, and a stored package that does not is never handed out.
func TestKeyPackagesMustCarryTheListedKey(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	group := f.group()
	registered := f.guestRegisteredDevice()
	listedKey := bytes.Repeat([]byte{10}, 32)
	otherKey := bytes.Repeat([]byte{99}, 32)

	// No list: any well-formed package is taken, as before L1.
	if _, err := f.store.PublishDeviceKeyPackages(ctx, registered, []NewDeviceKeyPackage{{
		KeyPackage: mlswiretest.KeyPackageWithSignatureKey(otherKey), Ciphersuite: openMLSCiphersuite, ExpiresAt: farFuture(),
	}}); err != nil {
		t.Fatalf("no list: %v", err)
	}
	f.seedHead(f.guest, registered)
	if _, err := f.store.PublishDeviceKeyPackages(ctx, registered, []NewDeviceKeyPackage{{
		KeyPackage: mlswiretest.KeyPackageWithSignatureKey(otherKey), Ciphersuite: openMLSCiphersuite, ExpiresAt: farFuture(),
	}}); !errors.Is(err, ErrKeyPackageNotListed) {
		t.Fatalf("another key with a list: err=%v, want ErrKeyPackageNotListed", err)
	}
	if _, err := f.store.PublishDeviceKeyPackages(ctx, registered, []NewDeviceKeyPackage{{
		KeyPackage: mlswiretest.KeyPackageWithSignatureKey(listedKey), Ciphersuite: openMLSCiphersuite, ExpiresAt: farFuture(),
	}}); err != nil {
		t.Fatalf("the listed key: %v", err)
	}

	// Every claim hands out only packages with the listed key; the stored
	// ones with another key (the fixture's and the pre-list one) are dropped.
	for i := 0; i < 2; i++ {
		claimed, err := f.store.ClaimDeviceKeyPackages(ctx, group.ID, f.owner.Account.ID, f.owner.Device.ID, []string{registered})
		if err != nil || len(claimed) != 1 {
			t.Fatalf("claim %d: %v %v", i, claimed, err)
		}
		leaf, err := mlswire.LeafSignatureKey(claimed[0].KeyPackage)
		if err != nil || !bytes.Equal(leaf, listedKey) {
			t.Fatalf("claim %d handed out a package with key %x", i, leaf)
		}
	}
	claimed, err := f.store.ClaimDeviceKeyPackages(ctx, group.ID, f.owner.Account.ID, f.owner.Device.ID, []string{registered})
	if err != nil || len(claimed) != 0 {
		t.Fatalf("no listed package left: %v %v", claimed, err)
	}
	if n, _ := countRows(ctx, f.store.db, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ? AND claimed_at IS NULL`, registered); n != 0 {
		t.Fatalf("%d unlisted packages kept", n)
	}
}

func farFuture() time.Time { return time.Date(2999, 1, 1, 0, 0, 0, 0, time.UTC) }
