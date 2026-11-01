package storage

import (
	"bytes"
	"context"
	"testing"
	"time"
)

// K0 R2 review follow-ups: storage rules.

// An instance set up after migration 0045 gets its decoy key lazily, from
// crypto/rand, once; later calls read it without the writer.
func TestRecoveryDecoyKeyIsCreatedOnceAndReadWithoutTheWriter(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	createTestOwner(t, ctx, store)
	if _, err := store.db.ExecContext(ctx, `UPDATE instances SET recovery_decoy_key = NULL WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	first, err := store.recoveryDecoyKey(ctx)
	if err != nil || len(first) != 32 {
		t.Fatalf("lazy decoy key = %x, err = %v", first, err)
	}
	if bytes.Equal(first, make([]byte, 32)) {
		t.Fatal("lazy decoy key is all zero")
	}
	var stored []byte
	if err := store.db.QueryRowContext(ctx, `SELECT recovery_decoy_key FROM instances WHERE id = 1`).Scan(&stored); err != nil || !bytes.Equal(stored, first) {
		t.Fatalf("stored key = %x, err = %v, want %x", stored, err, first)
	}

	// Hold the single writer connection: an existing key must still be
	// returned, unchanged, before a short deadline.
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	short, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()
	again, err := store.recoveryDecoyKey(short)
	if err != nil || !bytes.Equal(again, first) {
		t.Fatalf("decoy key while the writer is busy = %x, err = %v, want %x", again, err, first)
	}
}

// A claim that replaces a waiting request writes the same cancellation
// audit row as every other cancel.
func TestRecoveryClaimReplacementIsAudited(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	first := claimTestRecovery(t, ctx, store, owner, time.Hour)
	second := claimTestRecovery(t, ctx, store, owner, time.Hour)
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM audit_events WHERE event_type = 'account.recovery_cancelled'
		AND json_extract(metadata_json, '$.request_id') = ? AND json_extract(metadata_json, '$.reason') = ?`,
		first.request.ID, RecoveryCancelledReplaced); n != 1 {
		t.Fatalf("replacement audit rows = %d, want 1", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM audit_events WHERE event_type = 'account.recovery_cancelled'
		AND json_extract(metadata_json, '$.request_id') = ?`, second.request.ID); n != 0 {
		t.Fatalf("the waiting request has %d cancellation audit rows", n)
	}
}
