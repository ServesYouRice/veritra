package storage

import (
	"bytes"
	"context"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
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

// Completion ends account-only (restore) sessions as well as the old
// devices' sessions; another account's are untouched.
func TestRecoveryCompletionDeletesAccountOnlySessions(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	now := time.Now().UTC()
	for _, row := range []struct{ token, accountID string }{
		{"owner-restore", owner.Account.ID},
		{"bob-restore", bob.Account.ID},
	} {
		if _, err := store.db.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at)
			VALUES(?, ?, NULL, ?, ?, ?, ?, ?)`, auth.HashToken(row.token), row.accountID, formatTime(now.Add(time.Hour)), formatTime(now), formatTime(now), formatTime(now), formatTime(now.Add(time.Hour))); err != nil {
			t.Fatal(err)
		}
	}
	claim := claimTestRecovery(t, ctx, store, owner, 0)
	if _, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("recovered")); err != nil {
		t.Fatalf("complete: %v", err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE account_id = ? AND device_id IS NULL`, owner.Account.ID); n != 0 {
		t.Fatalf("recovered account kept %d account-only sessions", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE account_id = ? AND device_id IS NULL`, bob.Account.ID); n != 1 {
		t.Fatalf("another account's account-only sessions = %d, want 1", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sessions WHERE token_hash = ?`, auth.HashToken("recovered")); n != 1 {
		t.Fatal("the recovered session is missing")
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
