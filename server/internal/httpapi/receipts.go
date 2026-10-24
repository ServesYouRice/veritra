package httpapi

import (
	"context"
	"net/http"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
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

// recordDelivered notes that accountID's device was served these sync events
// and tells the other members, in realtime only, which delivery cursors
// moved. It is best effort: a failure never fails the sync page, and the
// announcement is never stored (a client reads the cursors again from
// GET /conversations/{id}/read-receipts).
func (a *API) recordDelivered(ctx context.Context, accountID string, events []domain.SyncEvent) {
	advanced, err := a.Store.RecordDelivered(ctx, accountID, events)
	if err != nil {
		a.warn("delivery_receipt_record_failed", "err", err)
		return
	}
	for _, advance := range advanced {
		members := a.conversationRecipientsForSender(ctx, advance.ConversationID, accountID)
		a.Hub.Publish(members, realtime.Event{
			Version:        "v1",
			Type:           "delivery_receipt.updated",
			ConversationID: advance.ConversationID,
			Payload:        map[string]string{"account_id": accountID, "message_id": advance.MessageID},
			CreatedAt:      time.Now().UTC(),
		})
	}
}
