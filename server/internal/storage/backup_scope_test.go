package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestDevicelessBackupCounterAndCapabilityRotation(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	sha := strings.Repeat("a", 64)
	tokenA, tokenB := bytes.Repeat([]byte{0xA1}, 32), bytes.Repeat([]byte{0xB2}, 32)

	if err := store.CreateBackupBlob(ctx, owner.Account.ID, "", "blob_deviceless_1", sha, 32, json.RawMessage(`{"state_counter":1}`), tokenA); err != nil {
		t.Fatalf("first device-less backup: %v", err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM backup_blobs WHERE account_id = ? AND device_id IS NULL`, owner.Account.ID); n != 1 {
		t.Fatalf("device-less backups = %d, want 1", n)
	}
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, "", "blob_deviceless_replay", sha, 32, json.RawMessage(`{"state_counter":1}`), bytes.Repeat([]byte{0xC3}, 32)); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("replayed state_counter: err = %v, want %v", err, ErrInvalidInput)
	}
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, "", "blob_deviceless_2", sha, 32, json.RawMessage(`{"state_counter":2}`), tokenB); err != nil {
		t.Fatalf("second device-less backup: %v", err)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, tokenA, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("recovery capability of the replaced backup: err = %v, want %v", err, ErrNotFound)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, tokenB, 0); err != nil {
		t.Fatalf("recovery capability of the newest backup: %v", err)
	}
	// A backup of a real device keeps its own counter and capability.
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_device_1", sha, 32, json.RawMessage(`{"state_counter":1}`), bytes.Repeat([]byte{0xD4}, 32)); err != nil {
		t.Fatalf("device backup with its own counter: %v", err)
	}
}

// Making a new backup revokes the recovery capability of the earlier one while
// it is still unused: only the newest capability recovers anything.
func TestNewBackupRevokesOutstandingRecoveryCapability(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	sha := strings.Repeat("e", 64)
	tokenA, tokenB := bytes.Repeat([]byte{0xA5}, 32), bytes.Repeat([]byte{0xB6}, 32)
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_rotation_1", sha, 8, json.RawMessage(`{"state_counter":1}`), tokenA); err != nil {
		t.Fatal(err)
	}
	// tokenA is live and unused: a transfer may begin with it (and is then
	// abandoned, which releases the lease without consuming the capability).
	first, err := store.BeginRecoveryTransfer(ctx, tokenA, 0)
	if err != nil {
		t.Fatalf("outstanding capability does not work before the rotation: %v", err)
	}
	if err := store.CompleteRecoveryTransfer(ctx, first.LeaseID, first.StartOffset, 0, 8); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_rotation_2", sha, 8, json.RawMessage(`{"state_counter":2}`), tokenB); err != nil {
		t.Fatal(err)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, tokenA, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("the earlier backup's unconsumed capability after a new backup: err = %v, want %v", err, ErrNotFound)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, tokenB, 0); err != nil {
		t.Fatalf("the newest capability: %v", err)
	}
}
