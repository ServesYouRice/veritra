package storage

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Deleting a message replaces its ciphertext with a marker. The ciphertext
// of the versions it replaced must not stay in, or replay from, the created
// and edited sync events; the deleted event carries the marker and keeps
// replaying, so members still learn of the delete.
func TestDeletedMessageVersionsAreNeitherReplayedNorKept(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	message, createdEvent := f.send(t, ctx, "deleted-original", nil)
	_, editedEvent, err := f.store.UpdateMessageEnvelopeWithSyncEvent(ctx, message.ID, f.sender.Account.ID, []byte("ciphertext-deleted-edit"), "mls-openmls-todo", nil)
	if err != nil || editedEvent == 0 {
		t.Fatalf("edit: event %d, err = %v", editedEvent, err)
	}
	_, keptEvent := f.send(t, ctx, "kept", nil)
	if seen := f.eventIDs(t, ctx, f.bystander); !seen[createdEvent] || !seen[editedEvent] {
		t.Fatalf("setup: events %d and %d are not replayed before the delete: %v", createdEvent, editedEvent, seen)
	}

	_, deletedEvent, err := f.store.DeleteMessageEnvelopeWithSyncEvent(ctx, message.ID, f.sender.Account.ID, []byte("ciphertext-delete-marker"), "mls-openmls-todo", nil)
	if err != nil || deletedEvent == 0 {
		t.Fatalf("delete: event %d, err = %v", deletedEvent, err)
	}

	for _, account := range []AccountDevice{f.bystander, f.sender} {
		seen := f.eventIDs(t, ctx, account)
		if seen[createdEvent] || seen[editedEvent] {
			t.Fatalf("created (%d) or edited (%d) event of a deleted message was replayed to %s", createdEvent, editedEvent, account.Account.Username)
		}
		if !seen[deletedEvent] || !seen[keptEvent] {
			t.Fatalf("%s misses the delete marker (%d) or the other message (%d): %v", account.Account.Username, deletedEvent, keptEvent, seen)
		}
	}
	for _, secret := range []string{"ciphertext-deleted-original", "ciphertext-deleted-edit"} {
		if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest(secret)); n != 0 {
			t.Fatalf("%d sync events still hold %q after the delete", n, secret)
		}
	}
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-delete-marker")); n != 1 {
		t.Fatalf("delete marker copies = %d, want 1 (the deleted event)", n)
	}
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-kept")); n != 1 {
		t.Fatalf("the other message's event lost its payload (%d copies)", n)
	}
	var payload string
	if err := f.store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, createdEvent).Scan(&payload); err != nil {
		t.Fatalf("the event row must survive redaction: %v", err)
	}
	if !strings.Contains(payload, message.ID) || strings.Contains(payload, "envelope") {
		t.Fatalf("redacted payload = %s, want the message id and no envelope", payload)
	}
	// A cursor on a redacted event still works.
	if _, err := f.store.ListSyncEvents(ctx, f.bystander.Account.ID, f.bystander.Device.ID, createdEvent, 50); err != nil {
		t.Fatalf("a cursor on a redacted event: %v", err)
	}
}

// Messages deleted before deletes redacted their events left the original
// ciphertext in the created event. Sync hides it at once, and the prune
// sweep's backfill takes the ciphertext out, leaving the delete marker.
func TestPruneBackfillRedactsVersionsOfMessagesDeletedEarlier(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	message, createdEvent := f.send(t, ctx, "deleted-long-ago", nil)
	var original string
	if err := f.store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, createdEvent).Scan(&original); err != nil {
		t.Fatal(err)
	}
	_, deletedEvent, err := f.store.DeleteMessageEnvelopeWithSyncEvent(ctx, message.ID, f.sender.Account.ID, []byte("ciphertext-old-marker"), "mls-openmls-todo", nil)
	if err != nil {
		t.Fatal(err)
	}
	// Put the pre-fix state back: the created event still holds the envelope.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE sync_events SET payload_json = ? WHERE id = ?`, original, createdEvent); err != nil {
		t.Fatal(err)
	}
	_, liveEvent := f.send(t, ctx, "still-live", nil)
	if seen := f.eventIDs(t, ctx, f.bystander); seen[createdEvent] || !seen[deletedEvent] || !seen[liveEvent] {
		t.Fatalf("bystander events = %v, want %d hidden and %d, %d replayed", seen, createdEvent, deletedEvent, liveEvent)
	}
	for sweep := 0; sweep < 4 && syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-deleted-long-ago")) != 0; sweep++ {
		if _, _, err := f.store.PruneExpiredContent(ctx, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-deleted-long-ago")); n != 0 {
		t.Fatalf("%d sync events still hold the deleted message's ciphertext after several sweeps", n)
	}
	for needle, want := range map[string]int{"ciphertext-old-marker": 1, "ciphertext-still-live": 1} {
		if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest(needle)); n != want {
			t.Fatalf("the backfill changed %q: %d copies, want %d", needle, n, want)
		}
	}
}
