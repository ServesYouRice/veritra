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

// deliveryQueue holds the delivery cursors waiting for a writer. A newer
// candidate for the same (account, conversation) replaces the older one, so
// the queue is bounded by the live cursors and a burst of sync pages is
// coalesced instead of dropped (a dropped write would never recover: the next
// catch-up page is empty).
type deliveryQueue struct {
	mu      sync.Mutex
	pending map[deliveryKey]string
	workers int
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
	if q.pending == nil {
		q.pending = map[deliveryKey]string{}
	}
	for _, advance := range candidates {
		q.pending[deliveryKey{accountID, advance.ConversationID}] = advance.MessageID
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
	for key, messageID := range q.pending {
		batch[key.accountID] = append(batch[key.accountID], storage.DeliveryAdvance{ConversationID: key.conversationID, MessageID: messageID})
		delete(q.pending, key)
	}
	return batch, true
}

func (a *API) runDeliveryWorker() {
	for {
		batch, ok := a.deliveries.take()
		if !ok {
			return
		}
		for accountID, candidates := range batch {
			a.writeDeliveries(accountID, candidates)
		}
	}
}

func (a *API) writeDeliveries(accountID string, candidates []storage.DeliveryAdvance) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(context.Background()), deliveryWriteTimeout)
	defer cancel()
	moved, err := a.Store.ApplyDeliveries(ctx, accountID, candidates)
	if err != nil {
		a.warn("delivery_receipt_record_failed", "err", err)
		return
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
}

// WaitDeliveryWrites blocks until the queued delivery writes are done or the
// deadline passes. The server calls it before storage closes.
func (a *API) WaitDeliveryWrites(deadline time.Time) {
	for time.Now().Before(deadline) {
		q := &a.deliveries
		q.mu.Lock()
		idle := q.workers == 0 && len(q.pending) == 0
		q.mu.Unlock()
		if idle {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}
