package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"
)

// A caller with no device cannot sign a device-list version, so on an account
// with a list the actions that must carry one fail closed (ErrForbidden)
// instead of skipping the rule (the Signer "" case of insertDeviceListTx).

func TestDevicelessCallerIsRefusedOnAnAccountWithAHead(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	store, owner := f.store, f.owner
	f.seedHead(owner.Account.ID, owner.Device.ID)
	someStatement := bytes.Repeat([]byte{1}, 64) // never parsed: the caller check comes first

	count := func(query string, args ...any) int {
		t.Helper()
		n, err := countRows(ctx, store.db, query, args...)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}

	t.Run("link approval", func(t *testing.T) {
		link, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute, testLinkLocator(t))
		if err != nil {
			t.Fatal(err)
		}
		transcript := claimLink(t, ctx, store, link, "Tablet")
		devices := count(`SELECT COUNT(*) FROM devices WHERE account_id = ?`, owner.Account.ID)
		for _, statement := range [][]byte{nil, someStatement} {
			_, _, _, _, _, err := store.ApproveDeviceLinkWithDeviceList(ctx, link.ID, owner.Account.ID, "", transcript, bytes.Repeat([]byte{9}, 32), statement)
			if !errors.Is(err, ErrForbidden) {
				t.Fatalf("approval with no caller device (statement %d bytes): %v, want ErrForbidden", len(statement), err)
			}
		}
		if _, _, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, transcript, bytes.Repeat([]byte{9}, 32)); !errors.Is(err, ErrForbidden) {
			t.Fatalf("legacy approval on an account with a head: %v, want ErrForbidden", err)
		}
		if got := count(`SELECT COUNT(*) FROM devices WHERE account_id = ?`, owner.Account.ID); got != devices {
			t.Fatalf("a refused approval created a device: %d devices, had %d", got, devices)
		}
		if got := count(`SELECT COUNT(*) FROM device_links WHERE id = ? AND state = 'claimed'`, link.ID); got != 1 {
			t.Fatal("a refused approval changed the link")
		}
		// The caller with a device still needs the version.
		if _, _, _, _, _, err := store.ApproveDeviceLinkWithDeviceList(ctx, link.ID, owner.Account.ID, owner.Device.ID, transcript, bytes.Repeat([]byte{9}, 32), nil); !errors.Is(err, ErrDeviceListRequired) {
			t.Fatalf("approval with a device and no version: %v, want ErrDeviceListRequired", err)
		}
	})

	t.Run("recovery key", func(t *testing.T) {
		key, rkID := bytes.Repeat([]byte{7}, 32), bytes.Repeat([]byte{9}, 16)
		for _, statement := range [][]byte{nil, someStatement} {
			if _, err := store.SetRecoveryKeyWithDeviceList(ctx, owner.Account.ID, "", key, rkID, statement); !errors.Is(err, ErrForbidden) {
				t.Fatalf("recovery key with no caller device (statement %d bytes): %v, want ErrForbidden", len(statement), err)
			}
		}
		if _, err := store.SetRecoveryKey(ctx, owner.Account.ID, key, rkID); !errors.Is(err, ErrForbidden) {
			t.Fatalf("legacy SetRecoveryKey on an account with a head: %v, want ErrForbidden", err)
		}
		if got := count(`SELECT COUNT(*) FROM account_recovery_keys WHERE account_id = ?`, owner.Account.ID); got != 0 {
			t.Fatal("a refused recovery key was stored")
		}
		if _, err := store.SetRecoveryKeyWithDeviceList(ctx, owner.Account.ID, owner.Device.ID, key, rkID, nil); !errors.Is(err, ErrDeviceListRequired) {
			t.Fatalf("recovery key with a device and no version: %v, want ErrDeviceListRequired", err)
		}
	})

	t.Run("publish", func(t *testing.T) {
		if _, _, err := store.PublishDeviceList(ctx, owner.Account.ID, "", someStatement); !errors.Is(err, ErrForbidden) {
			t.Fatalf("publish with no caller device: %v, want ErrForbidden", err)
		}
	})

	t.Run("revocation with a version", func(t *testing.T) {
		if _, err := store.db.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_extra', ?, 'Laptop', x'00', ?)`, owner.Account.ID, nowString()); err != nil {
			t.Fatal(err)
		}
		if _, _, err := store.RevokeDeviceWithDeviceList(ctx, owner.Account.ID, "", "dev_extra", someStatement); !errors.Is(err, ErrForbidden) {
			t.Fatalf("revocation with a version and no caller device: %v, want ErrForbidden", err)
		}
		if got := count(`SELECT COUNT(*) FROM devices WHERE id = 'dev_extra' AND revoked_at IS NULL`); got != 1 {
			t.Fatal("a refused revocation revoked the device")
		}
	})
}

// Accounts with no list stay as they were before L1, so a caller with no
// device and no version still works there.
func TestDevicelessCallerStillWorksOnAnAccountWithoutAHead(t *testing.T) {
	ctx := context.Background()
	f := newPendingFixture(t, ctx)
	if _, err := f.store.SetRecoveryKey(ctx, f.owner.Account.ID, bytes.Repeat([]byte{7}, 32), bytes.Repeat([]byte{9}, 16)); err != nil {
		t.Fatalf("recovery key on an account with no list: %v", err)
	}
}
