package storage

import (
	"context"
	"strings"
	"testing"
	"time"
)

func syncPayloadsContain(t *testing.T, ctx context.Context, store *Store, needle string) int {
	t.Helper()
	return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE instr(payload_json, ?) > 0`, needle)
}

// An expired message must not be replayed by sync, whatever the cursor, and
// pruning it must take its ciphertext out of every sync event that copied it.
func TestExpiredMessageEventsAreNeitherReplayedNorKept(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	// The bystander blocks nobody, so what it sees is what any member sees.
	soon := time.Now().UTC().Add(time.Hour)
	expiring, createdEvent := f.send(t, ctx, "expiring", &soon)
	edited, editedEvent, err := f.store.UpdateMessageEnvelopeWithSyncEvent(ctx, expiring.ID, f.sender.Account.ID, []byte("ciphertext-edited-secret"), "mls-openmls-todo", nil)
	if err != nil || editedEvent == 0 {
		t.Fatalf("edit: event %d, err = %v", editedEvent, err)
	}
	_ = edited
	deleted, deletedEvent, err := f.store.DeleteMessageEnvelopeWithSyncEvent(ctx, expiring.ID, f.sender.Account.ID, []byte("ciphertext-marker-secret"), "mls-openmls-todo", nil)
	if err != nil || deletedEvent == 0 {
		t.Fatalf("delete marker: event %d, err = %v", deletedEvent, err)
	}
	_ = deleted
	kept, keptEvent := f.send(t, ctx, "kept", nil)
	_ = kept
	events := []int64{createdEvent, editedEvent, deletedEvent}

	// Before expiry the delete marker and the other message replay; the
	// versions the delete replaced do not (TestDeletedMessageVersionsAreNeitherReplayedNorKept).
	seen := f.eventIDs(t, ctx, f.bystander)
	for _, id := range []int64{deletedEvent, keptEvent} {
		if !seen[id] {
			t.Fatalf("event %d is missing before the message expired: %v", id, seen)
		}
	}

	// Past expiry, but before the sweeper runs: the row is still there.
	f.expire(t, ctx, expiring.ID)
	seen = f.eventIDs(t, ctx, f.bystander)
	for _, id := range events {
		if seen[id] {
			t.Fatalf("event %d of an expired, unpruned message was replayed", id)
		}
	}
	if !seen[keptEvent] {
		t.Fatalf("the unexpired control message stopped replaying: %v", seen)
	}

	// After pruning: still hidden, and nothing of the ciphertext is left.
	if removed, _, err := f.store.PruneExpiredContent(ctx, time.Now().UTC()); err != nil || removed != 1 {
		t.Fatalf("prune removed %d, err = %v, want 1", removed, err)
	}
	seen = f.eventIDs(t, ctx, f.bystander)
	for _, id := range events {
		if seen[id] {
			t.Fatalf("event %d of a pruned message was replayed", id)
		}
	}
	for _, secret := range []string{"ciphertext-expiring", "ciphertext-edited-secret", "ciphertext-marker-secret"} {
		// Ciphertext travels base64 encoded inside the payload.
		if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest(secret)); n != 0 {
			t.Fatalf("%d sync events still hold %q after pruning", n, secret)
		}
	}
	var payload string
	if err := f.store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, createdEvent).Scan(&payload); err != nil {
		t.Fatalf("the event row must survive redaction: %v", err)
	}
	for _, want := range []string{expiring.ID, expiring.ConversationID, f.sender.Account.ID} {
		if !strings.Contains(payload, want) {
			t.Fatalf("redacted payload %s lost %q", payload, want)
		}
	}
	if strings.Contains(payload, "envelope") || strings.Contains(payload, "ciphertext") {
		t.Fatalf("redacted payload still has an envelope: %s", payload)
	}
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-kept")); n != 1 {
		t.Fatalf("the unexpired control message's event lost its payload (%d copies)", n)
	}
	// The cursor logic needs the rows: a client that stopped at a redacted
	// event is not told its cursor expired.
	if _, err := f.store.ListSyncEvents(ctx, f.bystander.Account.ID, f.bystander.Device.ID, createdEvent, 50); err != nil {
		t.Fatalf("a cursor on a redacted event: %v", err)
	}
}

// Events left behind by expiries pruned before events were redacted are
// cleaned by the bounded backfill of later sweeps, and only those: an event of
// a message that still has its envelope keeps its payload.
func TestPruneBackfillRedactsEventsOfMessagesThatAreAlreadyGone(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	_, keptEvent := f.send(t, ctx, "still-live", nil)
	leftover := func(messageID string) int64 {
		payload := `{"message_id":"` + messageID + `","conversation_id":"` + f.conversation.ID + `","envelope":{"id":"` + messageID + `","sender_account_id":"` + f.sender.Account.ID + `","ciphertext":"` + encodeBase64ForTest("leftover-secret-"+messageID) + `"}}`
		result, err := f.store.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('message.envelope.created', NULL, ?, ?, ?)`, f.conversation.ID, payload, nowString())
		if err != nil {
			t.Fatal(err)
		}
		id, _ := result.LastInsertId()
		return id
	}
	first := leftover("msg_gone_first")
	sweepUntilRedacted := func(needle string) {
		t.Helper()
		// The window covers a fixed range of event ids per sweep and wraps
		// to the start once it has passed the newest event.
		for sweep := 0; sweep < 4; sweep++ {
			if _, _, err := f.store.PruneExpiredContent(ctx, time.Now().UTC()); err != nil {
				t.Fatal(err)
			}
			if syncPayloadsContain(t, ctx, f.store, needle) == 0 {
				return
			}
		}
		t.Fatalf("%q is still in sync_events after several sweeps", needle)
	}
	sweepUntilRedacted(encodeBase64ForTest("leftover-secret-msg_gone_first"))
	var payload string
	if err := f.store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, first).Scan(&payload); err != nil || !strings.Contains(payload, "msg_gone_first") || !strings.Contains(payload, f.sender.Account.ID) || strings.Contains(payload, "envelope") {
		t.Fatalf("redacted leftover = %s, err = %v", payload, err)
	}
	// A leftover that appears after the cursor wrapped is found on a later pass.
	leftover("msg_gone_second")
	sweepUntilRedacted(encodeBase64ForTest("leftover-secret-msg_gone_second"))
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-still-live")); n != 1 {
		t.Fatalf("the backfill touched the live message's event: %d copies of its ciphertext", n)
	}
	if seen := f.eventIDs(t, ctx, f.bystander); !seen[keptEvent] {
		t.Fatalf("live message's event is no longer replayed: %v", seen)
	}
}

// After PruneSyncEvents removed the oldest events, the surviving ones start far
// above id zero. The backfill goes straight to them rather than crawling
// through the empty range one window per sweep.
func TestPruneBackfillSkipsTheGapLeftByPrunedSyncEvents(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	// Move the id counter far past the window, as a long-running instance's
	// pruned prefix does, then leave one leftover event up there.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE sqlite_sequence SET seq = 1000000 WHERE name = 'sync_events'`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM sync_events`); err != nil {
		t.Fatal(err)
	}
	payload := `{"message_id":"msg_gone_far","conversation_id":"` + f.conversation.ID + `","envelope":{"id":"msg_gone_far","sender_account_id":"` + f.sender.Account.ID + `","ciphertext":"` + encodeBase64ForTest("far-leftover-secret") + `"}}`
	result, err := f.store.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('message.envelope.created', NULL, ?, ?, ?)`, f.conversation.ID, payload, nowString())
	if err != nil {
		t.Fatal(err)
	}
	if id, _ := result.LastInsertId(); id <= 1000000 {
		t.Fatalf("leftover event id = %d, want it above the moved counter", id)
	}
	if _, _, err := f.store.PruneExpiredContent(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("far-leftover-secret")); n != 0 {
		t.Fatal("the backfill did not reach the surviving events in one sweep")
	}
}

func TestIdempotentRetryRedactsTheExpiredMessagesEvents(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	soon := time.Now().UTC().Add(time.Hour)
	first, firstEvent := f.send(t, ctx, "retry-redact", &soon)
	f.expire(t, ctx, first.ID)
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-retry-redact")); n != 1 {
		t.Fatalf("setup: %d copies of the ciphertext, want 1", n)
	}
	// The retry replaces the expired row, with the same ciphertext text, so
	// only the new copy may remain.
	_, secondEvent := f.send(t, ctx, "retry-redact", nil)
	if n := syncPayloadsContain(t, ctx, f.store, encodeBase64ForTest("ciphertext-retry-redact")); n != 1 {
		t.Fatalf("%d copies of the ciphertext after the retry, want only the new message's", n)
	}
	var payload string
	if err := f.store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, firstEvent).Scan(&payload); err != nil || strings.Contains(payload, "envelope") {
		t.Fatalf("expired message's event payload = %s, err = %v, want it redacted", payload, err)
	}
	if seen := f.eventIDs(t, ctx, f.bystander); seen[firstEvent] || !seen[secondEvent] {
		t.Fatalf("bystander events after the retry: %v, want only the new one (%d, not %d)", seen, secondEvent, firstEvent)
	}
}
