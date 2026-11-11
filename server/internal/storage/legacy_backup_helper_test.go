package storage

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"
	"context"
	"encoding/json"

	"private-messenger/server/internal/domain"
)

// insertLegacyBackup writes a kind-0 (VBK2) row directly. The upload path
// that made them is retired (K1-6), but old rows can still exist on a server
// that upgraded, so tests seed them by hand.
func insertLegacyBackup(ctx context.Context, s *Store, accountID, deviceID, storageKey, sha string, size int64, metadata json.RawMessage) error {
	id, err := domain.NewID("backup")
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		id, accountID, nullableEmptyString(deviceID), storageKey, sha, size, string(metadata), nowString())
	return err
}

// Migration 0080 clears every stored recovery capability (K1-6).
func TestRetireMigrationClearsRecoveryCapabilities(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	if err := insertLegacyBackup(ctx, store, owner.Account.ID, owner.Device.ID, "blob_retire", strings.Repeat("a", 64), 8, json.RawMessage(`{"state_counter":1}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE backup_blobs SET recovery_token_hash = ?, recovery_expires_at = ?,
		recovery_next_offset = 3, recovery_bytes_served = 3, recovery_lease_id = 'lease', recovery_lease_expires_at = ?`,
		bytes.Repeat([]byte{9}, 32), formatTime(time.Now().Add(time.Hour)), formatTime(time.Now().Add(time.Hour))); err != nil {
		t.Fatal(err)
	}
	script, err := os.ReadFile("../../migrations/0080_retire_backup_recovery_tokens.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, string(script)); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM backup_blobs WHERE recovery_token_hash IS NOT NULL OR recovery_lease_id IS NOT NULL OR recovery_expires_at IS NOT NULL OR recovery_next_offset <> 0`); n != 0 {
		t.Fatalf("live recovery state rows = %d", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM backup_blobs`); n != 1 {
		t.Fatalf("rows = %d", n)
	}
}
