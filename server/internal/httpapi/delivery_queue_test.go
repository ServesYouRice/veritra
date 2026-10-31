package httpapi

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
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

// While every writer is busy, a candidate is replaced only by one that is
// further along: an older sync page served late (another device, an
// overlapping request) must not discard a newer pending cursor (VAL-233).
func TestDeliveryQueueKeepsTheFurthestPendingCursor(t *testing.T) {
	api := &API{}
	q := &api.deliveries
	q.workers = maxDeliveryWriters
	t0 := time.Now()
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "newer", CreatedAt: t0.Add(time.Minute)}})
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "older", CreatedAt: t0}})
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c2", MessageID: "first", CreatedAt: t0}})
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c2", MessageID: "second", CreatedAt: t0.Add(time.Second)}})
	batch, ok := q.take()
	if !ok {
		t.Fatal("nothing pending")
	}
	got := map[string]string{}
	for _, advance := range batch["acct_a"] {
		got[advance.ConversationID] = advance.MessageID
	}
	if got["c1"] != "newer" {
		t.Fatalf("c1 pending = %q: an older candidate replaced the newer one", got["c1"])
	}
	if got["c2"] != "second" {
		t.Fatalf("c2 pending = %q: a newer candidate did not replace the older one", got["c2"])
	}
	q.workers = 0
}

// A failed write must not lose the advances it took: they go back into the
// queue (never replacing a newer candidate) and a later write persists them
// (VAL-231). The fake store applies the same monotonic rule as the real one.
func TestDeliveryQueueRequeuesOnWriteFailure(t *testing.T) {
	deliveryRetryBase = time.Millisecond
	t.Cleanup(func() { deliveryRetryBase = 100 * time.Millisecond })

	var (
		mu       sync.Mutex
		calls    int
		stored   = map[string]string{}
		released = make(chan struct{})
		entered  = make(chan struct{})
	)
	api := &API{}
	api.applyDeliveries = func(_ context.Context, accountID string, advances []storage.DeliveryAdvance) ([]storage.DeliveryAdvance, error) {
		mu.Lock()
		calls++
		first := calls == 1
		mu.Unlock()
		if first {
			close(entered)
			<-released
			return nil, errors.New("database is busy")
		}
		mu.Lock()
		defer mu.Unlock()
		for _, advance := range advances {
			key := accountID + "/" + advance.ConversationID
			if advance.MessageID > stored[key] {
				stored[key] = advance.MessageID
			}
		}
		return nil, nil
	}

	t0 := time.Now()
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "m1", CreatedAt: t0}, {ConversationID: "c2", MessageID: "m1", CreatedAt: t0}})
	<-entered
	// While the first write is in flight and about to fail, a newer cursor
	// for c1 arrives.
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "m2", CreatedAt: t0.Add(time.Second)}})
	close(released)
	api.WaitDeliveryWrites(time.Now().Add(5 * time.Second))

	mu.Lock()
	defer mu.Unlock()
	if stored["acct_a/c1"] != "m2" {
		t.Fatalf("c1 cursor = %q, want the newer m2 (a restored older advance regressed it, or it was lost)", stored["acct_a/c1"])
	}
	if stored["acct_a/c2"] != "m1" {
		t.Fatalf("c2 cursor = %q: the advance taken by the failed write was discarded", stored["acct_a/c2"])
	}
}

// Giving up on a batch that keeps failing drops that batch only. Cursors that
// other accounts queued in the meantime are still written.
func TestDeliveryQueueGivingUpKeepsOtherPendingCursors(t *testing.T) {
	deliveryRetryBase = time.Millisecond
	t.Cleanup(func() { deliveryRetryBase = 100 * time.Millisecond })
	var (
		mu     sync.Mutex
		calls  int
		stored = map[string]string{}
	)
	api := &API{}
	api.applyDeliveries = func(_ context.Context, accountID string, advances []storage.DeliveryAdvance) ([]storage.DeliveryAdvance, error) {
		mu.Lock()
		calls++
		n := calls
		mu.Unlock()
		if accountID == "acct_bad" {
			if n == maxDeliveryRetries+1 {
				// The last attempt before giving up: another account's
				// cursor arrives while this batch is being written.
				api.deliveries.mu.Lock()
				api.deliveries.mergeLocked("acct_good", storage.DeliveryAdvance{ConversationID: "c1", MessageID: "m1", CreatedAt: time.Now()})
				api.deliveries.mu.Unlock()
			}
			return nil, errors.New("database is locked")
		}
		mu.Lock()
		stored[accountID+"/"+advances[0].ConversationID] = advances[0].MessageID
		mu.Unlock()
		return nil, nil
	}
	api.recordDeliveredAsync("acct_bad", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "m1", CreatedAt: time.Now()}})
	api.WaitDeliveryWrites(time.Now().Add(10 * time.Second))
	mu.Lock()
	defer mu.Unlock()
	if stored["acct_good/c1"] != "m1" {
		t.Fatalf("another account's pending cursor was dropped with the failed batch: %v", stored)
	}
	if _, ok := stored["acct_bad/c1"]; ok {
		t.Fatal("the failing batch was written")
	}
	q := &api.deliveries
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.workers != 0 || len(q.pending) != 0 {
		t.Fatalf("queue not idle: workers=%d pending=%d", q.workers, len(q.pending))
	}
}

// The retry is bounded: a store that never recovers cannot keep a worker
// running, and shutdown still ends.
func TestDeliveryQueueGivesUpAfterBoundedRetries(t *testing.T) {
	deliveryRetryBase = time.Millisecond
	t.Cleanup(func() { deliveryRetryBase = 100 * time.Millisecond })
	var calls atomic.Int64
	api := &API{}
	api.applyDeliveries = func(context.Context, string, []storage.DeliveryAdvance) ([]storage.DeliveryAdvance, error) {
		calls.Add(1)
		return nil, errors.New("disk I/O error")
	}
	api.recordDeliveredAsync("acct_a", []storage.DeliveryAdvance{{ConversationID: "c1", MessageID: "m1"}})
	api.WaitDeliveryWrites(time.Now().Add(10 * time.Second))
	q := &api.deliveries
	q.mu.Lock()
	idle := q.workers == 0 && len(q.pending) == 0
	q.mu.Unlock()
	if !idle {
		t.Fatal("the worker kept retrying a store that never recovers")
	}
	if n := calls.Load(); n < 2 || n > int64(maxDeliveryRetries)+2 {
		t.Fatalf("%d write attempts, want a bounded number of retries (max %d)", n, maxDeliveryRetries)
	}
}
