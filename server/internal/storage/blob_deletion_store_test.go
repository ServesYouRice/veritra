package storage

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

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
