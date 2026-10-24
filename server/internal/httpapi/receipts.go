package httpapi

import (
	"context"
	"net/http"
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

// maxDeliveryWriters bounds the delivery writes in flight. A write that finds
// no free slot is dropped: the cursor catches up on the next page served.
const maxDeliveryWriters = 4

// deliveryWriteTimeout bounds one background delivery write.
const deliveryWriteTimeout = 3 * time.Second

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

// recordDeliveredAsync writes the cursors after the sync response has gone
// out and tells the other members, in realtime only, which ones moved. The
// announcement is never stored (a client reads the cursors again from
// GET /conversations/{id}/read-receipts). Best effort and bounded: it never
// delays or fails the sync page.
func (a *API) recordDeliveredAsync(accountID string, candidates []storage.DeliveryAdvance) {
	if len(candidates) == 0 {
		return
	}
	a.deliveryOnce.Do(func() { a.deliverySlots = make(chan struct{}, maxDeliveryWriters) })
	select {
	case a.deliverySlots <- struct{}{}:
	default:
		return
	}
	go func() {
		defer func() { <-a.deliverySlots }()
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
	}()
}
