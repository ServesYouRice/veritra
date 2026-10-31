package storage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

func TestDeleteAttachmentCommitsDeletionQueueAtomically(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	attachment, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
		OwnerAccountID: owner.Account.ID, ConversationID: &conversation.ID,
		StorageKey: "blob_00000000000000000000000000000000", CiphertextSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		SizeBytes: 10, CryptoMetadata: json.RawMessage(`{"v":1}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.DeleteAttachment(ctx, attachment.ID, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	keys, err := store.PendingBlobDeletions(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0] != attachment.StorageKey {
		t.Fatalf("pending keys = %#v", keys)
	}
	if err := store.RecordBlobDeletionFailure(ctx, attachment.StorageKey); err != nil {
		t.Fatal(err)
	}
	var attempts int
	if err := store.db.QueryRowContext(ctx, `SELECT attempts FROM blob_deletion_queue WHERE storage_key = ?`, attachment.StorageKey).Scan(&attempts); err != nil {
		t.Fatal(err)
	}
	if attempts != 1 {
		t.Fatalf("attempts = %d, want 1", attempts)
	}
	if err := store.CompleteBlobDeletion(ctx, attachment.StorageKey); err != nil {
		t.Fatal(err)
	}
	keys, err = store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 0 {
		t.Fatalf("pending after completion = %#v, err = %v", keys, err)
	}
}

func TestDeleteAttachmentRollsBackWhenCleanupQueueFails(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	attachment, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
		OwnerAccountID: owner.Account.ID, ConversationID: &conversation.ID,
		StorageKey: "blob_00000000000000000000000000000001", CiphertextSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		SizeBytes: 10, CryptoMetadata: json.RawMessage(`{"v":1}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `CREATE TRIGGER fail_blob_deletion_queue BEFORE INSERT ON blob_deletion_queue BEGIN SELECT RAISE(ABORT, 'injected queue failure'); END`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DeleteAttachment(ctx, attachment.ID, owner.Account.ID); err == nil {
		t.Fatal("DeleteAttachment succeeded")
	}
	if _, err := store.AttachmentForAccount(ctx, attachment.ID, owner.Account.ID); err != nil {
		t.Fatalf("attachment was not rolled back: %v", err)
	}
}

func TestDeleteBackupQueuesBlob(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	key := "blob_00000000000000000000000000000002"
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, key, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", 10, json.RawMessage(`{"state_counter":1}`), make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	backups, err := store.ListBackups(ctx, owner.Account.ID, 10)
	if err != nil || len(backups) != 1 {
		t.Fatalf("backups = %#v, err = %v", backups, err)
	}
	if _, err := store.DeleteBackup(ctx, backups[0].ID, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	keys, err := store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 1 || keys[0] != key {
		t.Fatalf("pending keys = %#v, err = %v", keys, err)
	}
	if _, err := store.BackupForAccount(ctx, backups[0].ID, owner.Account.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("backup lookup error = %v, want not found", err)
	}
}

func TestPendingBlobDeletionsReturnsFreshKeysBeforeRepeatedFailures(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	old := formatTime(time.Now().UTC().Add(-48 * time.Hour))
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 500; i++ {
		key := fmt.Sprintf("blob_failing_%032d", i)
		if _, err := tx.ExecContext(ctx, `INSERT INTO blob_deletion_queue(storage_key, created_at, attempts, last_attempt_at) VALUES(?, ?, 3, ?)`, key, old, old); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	fresh := "blob_fresh_00000000000000000000000000"
	if err := store.QueueBlobDeletion(ctx, fresh); err != nil {
		t.Fatal(err)
	}
	keys, err := store.PendingBlobDeletions(ctx, 500)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 500 || keys[0] != fresh {
		first := ""
		if len(keys) > 0 {
			first = keys[0]
		}
		t.Fatalf("pending = %d keys starting with %q, want 500 keys starting with the never-attempted key", len(keys), first)
	}
}

func TestPendingBlobDeletionsClampsLargeLimitAndDefaultsSmallOnes(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 600; i++ {
		if _, err := tx.ExecContext(ctx, `INSERT INTO blob_deletion_queue(storage_key, created_at) VALUES(?, ?)`, fmt.Sprintf("blob_clamp_%032d", i), nowString()); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ limit, want int }{{0, 100}, {-5, 100}, {7, 7}, {500, 500}, {501, 500}, {100000, 500}} {
		keys, err := store.PendingBlobDeletions(ctx, tc.limit)
		if err != nil {
			t.Fatal(err)
		}
		if len(keys) != tc.want {
			t.Errorf("PendingBlobDeletions(%d) returned %d keys, want %d", tc.limit, len(keys), tc.want)
		}
	}
}
