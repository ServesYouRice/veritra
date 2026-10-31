package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func newRecoveryLeaseStore(t *testing.T, ctx context.Context, token []byte) (*Store, AccountDevice) {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "recovery-lease-blob", strings.Repeat("a", 64), 6, json.RawMessage(`{"state_counter":1}`), token); err != nil {
		t.Fatalf("create backup: %v", err)
	}
	return store, owner
}

func setRecoveryTimes(t *testing.T, ctx context.Context, store *Store, token []byte, capabilityExpiresIn, leaseExpiresIn time.Duration) {
	t.Helper()
	now := time.Now().UTC()
	if _, err := store.db.ExecContext(ctx, `UPDATE backup_blobs SET recovery_expires_at = ?, recovery_lease_expires_at = ? WHERE recovery_token_hash = ?`,
		formatTime(now.Add(capabilityExpiresIn)), formatTime(now.Add(leaseExpiresIn)), token); err != nil {
		t.Fatalf("set recovery times: %v", err)
	}
}

func TestRecoveryLeaseRenewalLetsTransferFinishPastCapabilityExpiry(t *testing.T) {
	ctx := context.Background()
	token := bytes.Repeat([]byte{0x31}, 32)
	store, _ := newRecoveryLeaseStore(t, ctx, token)

	transfer, err := store.BeginRecoveryTransfer(ctx, token, 0)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	// The initial lease is a full lease even when the capability is about to
	// expire: it is no longer cut off at the capability deadline.
	if _, err := store.db.ExecContext(ctx, `UPDATE backup_blobs SET recovery_expires_at = ? WHERE recovery_lease_id = ?`, formatTime(time.Now().UTC().Add(10*time.Second)), transfer.LeaseID); err != nil {
		t.Fatal(err)
	}
	if err := store.RenewRecoveryTransfer(ctx, transfer.LeaseID); err != nil {
		t.Fatalf("renew: %v", err)
	}
	var leaseExpires, capabilityExpires string
	if err := store.db.QueryRowContext(ctx, `SELECT recovery_lease_expires_at, recovery_expires_at FROM backup_blobs WHERE recovery_lease_id = ?`, transfer.LeaseID).Scan(&leaseExpires, &capabilityExpires); err != nil {
		t.Fatal(err)
	}
	if !parseTime(leaseExpires).After(parseTime(capabilityExpires).Add(time.Minute)) {
		t.Fatalf("renewed lease %s does not outlive the capability %s", leaseExpires, capabilityExpires)
	}
	// A live lease still keeps every other caller out.
	if _, err := store.BeginRecoveryTransfer(ctx, token, 0); !errors.Is(err, ErrRecoveryBusy) {
		t.Fatalf("second caller during a renewed lease: err = %v, want %v", err, ErrRecoveryBusy)
	}
	// The capability expires while the stream runs; the holder still finishes.
	setRecoveryTimes(t, ctx, store, token, -time.Minute, time.Minute)
	if err := store.CompleteRecoveryTransfer(ctx, transfer.LeaseID, transfer.StartOffset, 6, 6); err != nil {
		t.Fatalf("complete after capability expiry: %v", err)
	}
	var offset int64
	var tokenHash []byte
	if err := store.db.QueryRowContext(ctx, `SELECT recovery_next_offset, recovery_token_hash FROM backup_blobs WHERE storage_key = 'recovery-lease-blob'`).Scan(&offset, &tokenHash); err != nil {
		t.Fatal(err)
	}
	if offset != 6 || tokenHash != nil {
		t.Fatalf("offset = %d, token hash = %x, want a consumed capability at offset 6", offset, tokenHash)
	}
}

func TestRecoveryLeaseCannotStartAfterCapabilityExpiry(t *testing.T) {
	ctx := context.Background()
	token := bytes.Repeat([]byte{0x32}, 32)
	store, _ := newRecoveryLeaseStore(t, ctx, token)
	setRecoveryTimes(t, ctx, store, token, -time.Second, -time.Minute)
	if _, err := store.BeginRecoveryTransfer(ctx, token, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("begin after expiry: err = %v, want %v", err, ErrNotFound)
	}
}

func TestRecoveryLeaseLapsedHolderCannotRenewOrComplete(t *testing.T) {
	ctx := context.Background()
	token := bytes.Repeat([]byte{0x33}, 32)
	store, _ := newRecoveryLeaseStore(t, ctx, token)
	first, err := store.BeginRecoveryTransfer(ctx, token, 0)
	if err != nil {
		t.Fatal(err)
	}
	// The first holder stops renewing and its lease lapses; another caller
	// takes over.
	setRecoveryTimes(t, ctx, store, token, 10*time.Minute, -time.Second)
	if err := store.RenewRecoveryTransfer(ctx, first.LeaseID); !errors.Is(err, ErrRecoveryBusy) {
		t.Fatalf("renewing a lapsed lease: err = %v, want %v", err, ErrRecoveryBusy)
	}
	second, err := store.BeginRecoveryTransfer(ctx, token, 0)
	if err != nil {
		t.Fatalf("takeover: %v", err)
	}
	if err := store.RenewRecoveryTransfer(ctx, first.LeaseID); !errors.Is(err, ErrRecoveryBusy) {
		t.Fatalf("renewing a replaced lease: err = %v, want %v", err, ErrRecoveryBusy)
	}
	if err := store.CompleteRecoveryTransfer(ctx, first.LeaseID, first.StartOffset, 6, 6); !errors.Is(err, ErrRecoveryBusy) {
		t.Fatalf("stale completion: err = %v, want %v", err, ErrRecoveryBusy)
	}
	if err := store.RenewRecoveryTransfer(ctx, second.LeaseID); err != nil {
		t.Fatalf("current holder renews: %v", err)
	}
	if err := store.RenewRecoveryTransfer(ctx, ""); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("empty lease id: err = %v, want %v", err, ErrInvalidInput)
	}
}
