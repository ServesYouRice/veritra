package storage

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

// T49B miss 6: chunk-digest records are stored with the blob row, read only
// where a download needs them, never serialized, and filled in for legacy
// rows only when the row still holds the digest and size that were verified.
func TestBlobChunkDigestRecords(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	sha := strings.Repeat("a", 64)
	record := []byte{1, 2, 3}
	withRecord, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
		OwnerAccountID: owner.Account.ID, ConversationID: &conversation.ID, StorageKey: "blob_with_record",
		CiphertextSHA256: sha, SizeBytes: 10, ChunkDigests: record,
	})
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
		OwnerAccountID: owner.Account.ID, ConversationID: &conversation.ID, StorageKey: "blob_legacy",
		CiphertextSHA256: sha, SizeBytes: 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.AttachmentForAccount(ctx, withRecord.ID, owner.Account.ID)
	if err != nil || !bytes.Equal(got.ChunkDigests, record) {
		t.Fatalf("record = %v, err %v", got.ChunkDigests, err)
	}
	if encoded, _ := json.Marshal(got); bytes.Contains(encoded, []byte("chunk")) {
		t.Fatalf("record serialized: %s", encoded)
	}
	listed, err := store.ListAttachments(ctx, owner.Account.ID, 10)
	if err != nil || len(listed) != 2 || listed[0].ChunkDigests != nil || listed[1].ChunkDigests != nil {
		t.Fatalf("list loaded records: %v", err)
	}

	attachmentRecord := func(id string) []byte {
		t.Helper()
		attachment, err := store.AttachmentForAccount(ctx, id, owner.Account.ID)
		if err != nil {
			t.Fatal(err)
		}
		return attachment.ChunkDigests
	}
	if attachmentRecord(legacy.ID) != nil {
		t.Fatal("legacy row has a record")
	}
	rebuilt := []byte{7, 7}
	other := strings.Repeat("b", 64)
	for _, call := range []struct {
		sha  string
		size int64
	}{{other, 10}, {sha, 11}} {
		if err := store.RecordBlobChunkDigests(ctx, "blob_legacy", call.sha, call.size, rebuilt); err != nil {
			t.Fatal(err)
		}
		if attachmentRecord(legacy.ID) != nil {
			t.Fatalf("record stored for a row that no longer matches (%s, %d)", call.sha[:1], call.size)
		}
	}
	if err := store.RecordBlobChunkDigests(ctx, "blob_legacy", sha, 10, rebuilt); err != nil || !bytes.Equal(attachmentRecord(legacy.ID), rebuilt) {
		t.Fatalf("backfill = %v, err %v", attachmentRecord(legacy.ID), err)
	}
	for _, key := range []string{"blob_legacy", "blob_with_record"} {
		if err := store.RecordBlobChunkDigests(ctx, key, sha, 10, []byte{9}); err != nil {
			t.Fatal(err)
		}
	}
	if !bytes.Equal(attachmentRecord(legacy.ID), rebuilt) || !bytes.Equal(attachmentRecord(withRecord.ID), record) {
		t.Fatal("an existing record was replaced")
	}
	if err := store.RecordBlobChunkDigests(ctx, "", sha, 10, rebuilt); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("empty key = %v", err)
	}
	if err := store.RecordBlobChunkDigests(ctx, "blob_legacy", sha, 10, nil); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("empty record = %v", err)
	}

	// Backups: the record reaches downloads and recovery transfers.
	tokenHash := sha256.Sum256([]byte("recovery token"))
	if err := store.CreateBackupBlobWithChunkDigests(ctx, owner.Account.ID, owner.Device.ID, "blob_backup_record", sha, 10, record,
		json.RawMessage(`{"state_counter":1}`), tokenHash[:]); err != nil {
		t.Fatal(err)
	}
	transfer, err := store.BeginRecoveryTransfer(ctx, tokenHash[:], 0)
	if err != nil || !bytes.Equal(transfer.Backup.ChunkDigests, record) {
		t.Fatalf("recovery record = %v, err %v", transfer.Backup.ChunkDigests, err)
	}
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_backup_legacy", sha, 10,
		json.RawMessage(`{"state_counter":2}`), make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	backups, err := store.ListBackups(ctx, owner.Account.ID, 10)
	if err != nil || len(backups) != 2 {
		t.Fatalf("backups = %d, err %v", len(backups), err)
	}
	for _, backup := range backups {
		got, err := store.BackupForAccount(ctx, backup.ID, owner.Account.ID)
		if err != nil {
			t.Fatal(err)
		}
		want := record
		if got.StorageKey == "blob_backup_legacy" {
			want = nil
			if err := store.RecordBlobChunkDigests(ctx, got.StorageKey, sha, 10, rebuilt); err != nil {
				t.Fatal(err)
			}
			if again, _ := store.BackupForAccount(ctx, backup.ID, owner.Account.ID); !bytes.Equal(again.ChunkDigests, rebuilt) {
				t.Fatalf("backup backfill = %v", again.ChunkDigests)
			}
		}
		if !bytes.Equal(got.ChunkDigests, want) {
			t.Fatalf("%s record = %v", got.StorageKey, got.ChunkDigests)
		}
	}
}

// Rows written before migration 0034 keep working: they read back with no
// record (so the blob store verifies them in full) and can receive one.
func TestChunkDigestMigrationLeavesExistingBlobsLegacy(t *testing.T) {
	ctx := context.Background()
	store, _ := openBareStoreAt(t)
	old, _ := migrationsUpTo(t, "0033")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	seedHistorical(t, store)
	sha := strings.Repeat("c", 64)
	for _, statement := range []string{
		`INSERT INTO attachment_envelopes(id, owner_account_id, conversation_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at)
			VALUES('att_old', 'acct_a', 'conv_dm', 'blob_old_attachment', '` + sha + `', 5, '{}', '2026-01-01T00:00:00Z')`,
		`INSERT INTO backup_blobs(id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at)
			VALUES('backup_old', 'acct_a', 'dev_a', 'blob_old_backup', '` + sha + `', 6, '{}', '2026-01-01T00:00:00Z')`,
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	attachment, err := store.AttachmentForAccount(ctx, "att_old", "acct_a")
	if err != nil || attachment.ChunkDigests != nil {
		t.Fatalf("upgraded attachment record = %v, err %v", attachment.ChunkDigests, err)
	}
	backup, err := store.BackupForAccount(ctx, "backup_old", "acct_a")
	if err != nil || backup.ChunkDigests != nil {
		t.Fatalf("upgraded backup record = %v, err %v", backup.ChunkDigests, err)
	}
	if err := store.RecordBlobChunkDigests(ctx, "blob_old_attachment", sha, 5, []byte{1}); err != nil {
		t.Fatal(err)
	}
	if attachment, _ = store.AttachmentForAccount(ctx, "att_old", "acct_a"); !bytes.Equal(attachment.ChunkDigests, []byte{1}) {
		t.Fatalf("backfilled record = %v", attachment.ChunkDigests)
	}
	var instanceUsage int64
	if err := store.db.QueryRowContext(ctx, `SELECT size_bytes FROM blob_usage_instance WHERE id = 1`).Scan(&instanceUsage); err != nil || instanceUsage != 11 {
		t.Fatalf("quota counter = %d after record update, err %v", instanceUsage, err)
	}
}
