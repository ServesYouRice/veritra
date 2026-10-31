package httpapi

import (
	"context"
	"net/http"
	"sync"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

func (a *API) getReadReceiptsSetting(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	enabled, err := a.Store.ReadReceiptsEnabled(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"enabled": enabled})
}

func (a *API) putReadReceiptsSetting(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		Enabled *bool `json:"enabled"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Enabled == nil {
		writeError(w, http.StatusBadRequest, "enabled_required")
		return
	}
	if err := a.Store.SetReadReceiptsEnabled(r.Context(), principal.AccountID, *req.Enabled); err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"enabled": *req.Enabled})
}

// maxDeliveryWriters bounds the delivery writes in flight.
const maxDeliveryWriters = 4

// deliveryWriteTimeout bounds one background delivery write.
const deliveryWriteTimeout = 3 * time.Second

// deliveryKey identifies the cursor a pending write moves.
type deliveryKey struct{ accountID, conversationID string }

// deliveryQueue holds the delivery cursors waiting for a writer. For the same
// (account, conversation) a candidate replaces the pending one only when it
// is not older (merge), so the queue is bounded by the live cursors, a burst
// of sync pages is coalesced instead of dropped (a dropped write would never
// recover: the next catch-up page is empty), and a late older page cannot
// discard a newer pending cursor.
type deliveryQueue struct {
	mu      sync.Mutex
	pending map[deliveryKey]storage.DeliveryAdvance
	workers int
	// stopped is set when shutdown gave up waiting: workers stop retrying.
	stopped bool
}

// deliveryCandidates reads which delivery cursors a sync page served to
// accountID would move. Best effort: an error means no delivery is recorded.
func (a *API) deliveryCandidates(ctx context.Context, accountID string, events []domain.SyncEvent) []storage.DeliveryAdvance {
	candidates, err := a.Store.DeliveryCandidates(ctx, accountID, events)
	if err != nil {
		a.warn("delivery_receipt_check_failed", "err", err)
		return nil
	}
	return candidates
}

// recordDeliveredAsync queues the cursors; bounded workers write them after
// the sync response has gone out and tell the other members, in realtime
// only, which ones moved. The announcement is never stored (a client reads
// the cursors again from GET /conversations/{id}/read-receipts). Best effort
// and bounded: it never delays or fails the sync page, and a full set of
// workers coalesces the write into the queue.
func (a *API) recordDeliveredAsync(accountID string, candidates []storage.DeliveryAdvance) {
	if len(candidates) == 0 {
		return
	}
	q := &a.deliveries
	q.mu.Lock()
	for _, advance := range candidates {
		q.mergeLocked(accountID, advance)
	}
	start := q.workers < maxDeliveryWriters
	if start {
		q.workers++
	}
	q.mu.Unlock()
	if start {
		go a.runDeliveryWorker()
	}
}

// take removes everything pending, grouped by account, and says whether the
// worker may keep running. When nothing is pending the worker slot
// is released under the same lock, so a candidate queued just after never
// finds every slot taken by workers that are about to exit.
func (q *deliveryQueue) take() (map[string][]storage.DeliveryAdvance, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.pending) == 0 {
		q.workers--
		return nil, false
	}
	batch := map[string][]storage.DeliveryAdvance{}
	for key, advance := range q.pending {
		batch[key.accountID] = append(batch[key.accountID], advance)
		delete(q.pending, key)
	}
	return batch, true
}

// mergeLocked queues advance unless a pending one for the same cursor is
// further along. Messages are ordered by created_at, the order ApplyDeliveries
// keeps the stored cursor monotonic by; equal or unknown times let the later
// arrival win. q.mu must be held.
func (q *deliveryQueue) mergeLocked(accountID string, advance storage.DeliveryAdvance) {
	if q.pending == nil {
		q.pending = map[deliveryKey]storage.DeliveryAdvance{}
	}
	key := deliveryKey{accountID, advance.ConversationID}
	if current, ok := q.pending[key]; ok && advance.CreatedAt.Before(current.CreatedAt) {
		return
	}
	q.pending[key] = advance
}

// requeue puts the advances of a failed write back, never replacing a pending
// candidate that is further along.
func (q *deliveryQueue) requeue(accountID string, advances []storage.DeliveryAdvance) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, advance := range advances {
		q.mergeLocked(accountID, advance)
	}
}

func (q *deliveryQueue) isStopped() bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.stopped
}

func (a *API) runDeliveryWorker() {
	failures := 0
	for {
		batch, ok := a.deliveries.take()
		if !ok {
			return
		}
		failed := map[string][]storage.DeliveryAdvance{}
		for accountID, candidates := range batch {
			if !a.writeDeliveries(accountID, candidates) {
				failed[accountID] = candidates
			}
		}
		if len(failed) == 0 {
			failures = 0
			continue
		}
		// The store refused a write: keep those advances and retry after a
		// growing pause, a bounded number of times. Past that, or once
		// shutdown stopped waiting, only the failed advances are dropped
		// (counted, not named); cursors other accounts queued meanwhile stay.
		if failures++; failures > maxDeliveryRetries || a.deliveries.isStopped() {
			dropped := 0
			for _, candidates := range failed {
				dropped += len(candidates)
			}
			a.warn("delivery_receipts_dropped", "cursors", dropped)
			failures = 0
			continue
		}
		for accountID, candidates := range failed {
			a.deliveries.requeue(accountID, candidates)
		}
		time.Sleep(min(deliveryRetryBase<<(failures-1), deliveryRetryCap))
	}
}

// deliveryRetryBase is the first wait before a failed delivery write is
// retried; each further attempt doubles it up to deliveryRetryCap. Tests
// shorten it.
var deliveryRetryBase = 100 * time.Millisecond

const (
	deliveryRetryCap = 2 * time.Second
	// maxDeliveryRetries bounds how many times a batch is retried before
	// its advances are dropped (the store is down, not busy).
	maxDeliveryRetries = 6
)

func (a *API) writeDeliveries(accountID string, candidates []storage.DeliveryAdvance) bool {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(context.Background()), deliveryWriteTimeout)
	defer cancel()
	apply := a.Store.ApplyDeliveries
	if a.applyDeliveries != nil {
		apply = a.applyDeliveries
	}
	moved, err := apply(ctx, accountID, candidates)
	if err != nil {
		a.warn("delivery_receipt_record_failed", "err", err)
		return false
	}
	for _, advance := range moved {
		members, err := a.Store.ReceiptRecipients(ctx, advance.ConversationID, accountID)
		if err != nil {
			a.warn("delivery_receipt_recipients_failed", "err", err)
			continue
		}
		a.Hub.Publish(members, realtime.Event{
			Version:        "v1",
			Type:           "delivery_receipt.updated",
			ConversationID: advance.ConversationID,
			Payload:        map[string]string{"account_id": accountID, "message_id": advance.MessageID},
			CreatedAt:      time.Now().UTC(),
		})
	}
	return true
}

// WaitDeliveryWrites blocks until the queued delivery writes are done or the
// deadline passes. The server calls it before storage closes. If the
// deadline passes first, workers stop retrying failed writes.
func (a *API) WaitDeliveryWrites(deadline time.Time) {
	q := &a.deliveries
	for time.Now().Before(deadline) {
		q.mu.Lock()
		idle := q.workers == 0 && len(q.pending) == 0
		q.mu.Unlock()
		if idle {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	q.mu.Lock()
	q.stopped = true
	q.mu.Unlock()
}
