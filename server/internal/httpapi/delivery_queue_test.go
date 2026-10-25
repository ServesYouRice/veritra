package httpapi

import (
	"testing"
	"time"

	"private-messenger/server/internal/storage"
)

// With every writer busy a candidate is queued, not dropped, and a newer one
// for the same (account, conversation) replaces the older.
func TestDeliveryQueueCoalescesWhenWritersAreBusy(t *testing.T) {
	api := &API{}
	q := &api.deliveries
	q.workers = maxDeliveryWriters // all slots taken: no goroutine is started
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "m1"}, {ConversationID: "c2", MessageID: "m1"}})
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "m2"}})
	api.recordDeliveredAsync("acct_b", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "m3"}})
	if q.workers != maxDeliveryWriters {
		t.Fatalf("workers=%d: a worker started past the bound", q.workers)
	}

	batch, ok := q.take()
	if !ok || len(batch["acct_a"]) != 2 || len(batch["acct_b"]) != 1 {
		t.Fatalf("batch=%v ok=%v", batch, ok)
	}
	for _, advance := range batch["acct_a"] {
		if advance.ConversationID == "c1" && advance.MessageID != "m2" {
			t.Fatalf("c1 kept %s, want the latest candidate m2", advance.MessageID)
		}
	}
	// Drained: the worker slot is released with the empty take.
	if batch, ok = q.take(); ok || batch != nil || q.workers != maxDeliveryWriters-1 {
		t.Fatalf("empty take: batch=%v ok=%v workers=%d", batch, ok, q.workers)
	}
	q.workers = 0
	api.WaitDeliveryWrites(time.Now().Add(time.Second)) // nothing pending: returns at once
}
