package storage

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Every backlog entry mirrors a prune predicate: while rows wait for the
// prune the backlog counts them, and after the prune it reads zero.
func TestRetentionBacklogCountsOrphanedAttachmentsAndAgedSyncEvents(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	now := time.Now().UTC()
	const syncRetention = 30 * 24 * time.Hour
	attachment := func(id string, age time.Duration) {
		t.Helper()
		if _, err := store.db.ExecContext(ctx, `INSERT INTO attachment_envelopes(id, owner_account_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at) VALUES(?, ?, ?, ?, 1, '{}', ?)`,
			id, owner.Account.ID, "blob_"+id, strings.Repeat("d", 64), formatTime(now.Add(-age))); err != nil {
			t.Fatal(err)
		}
	}
	syncEvent := func(age time.Duration) {
		t.Helper()
		if _, err := store.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('test.event', ?, NULL, '{}', ?)`,
			owner.Account.ID, formatTime(now.Add(-age))); err != nil {
			t.Fatal(err)
		}
	}
	attachment("att_orphan_old", 25*time.Hour) // prunable for an hour
	attachment("att_orphan_new", time.Hour)    // still inside the grace period
	syncEvent(syncRetention + 24*time.Hour)    // prunable for a day
	syncEvent(time.Hour)                       // recent
	existing := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE created_at < ?`, formatTime(now.Add(-syncRetention)))
	if existing != 1 {
		t.Fatalf("setup: %d aged sync events, want 1", existing)
	}

	backlog, err := store.RetentionBacklogWithSyncRetention(ctx, now, syncRetention)
	if err != nil {
		t.Fatal(err)
	}
	if backlog.Rows != 2 {
		t.Fatalf("backlog rows = %d, want the orphaned attachment and the aged sync event", backlog.Rows)
	}
	if age := time.Duration(backlog.OldestAgeSecond) * time.Second; age < 23*time.Hour || age > 25*time.Hour {
		t.Fatalf("oldest backlog age = %s, want about a day (the aged sync event)", age)
	}
	// Without the retention the sync events are not counted.
	if plain, err := store.RetentionBacklog(ctx, now); err != nil || plain.Rows != 1 {
		t.Fatalf("backlog without sync retention = %#v, err = %v, want only the attachment", plain, err)
	}

	_, storageKeys, err := store.PruneExpiredContent(ctx, now)
	if err != nil || len(storageKeys) != 1 {
		t.Fatalf("prune returned %d blob keys, err = %v, want the orphan's", len(storageKeys), err)
	}
	// The sweep then deletes the queued blob, which empties the deletion queue.
	for _, key := range storageKeys {
		if err := store.CompleteBlobDeletion(ctx, key); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.PruneSyncEvents(ctx, now.Add(-syncRetention)); err != nil {
		t.Fatal(err)
	}
	backlog, err = store.RetentionBacklogWithSyncRetention(ctx, now, syncRetention)
	if err != nil || backlog.Rows != 0 || backlog.OldestAgeSecond != 0 {
		t.Fatalf("backlog after the prune = %#v, err = %v, want zero", backlog, err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM attachment_envelopes WHERE id = 'att_orphan_new'`); n != 1 {
		t.Fatal("the attachment inside its grace period was pruned")
	}
}
