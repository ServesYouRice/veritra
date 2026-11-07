package httpapi

import (
	"errors"
	"net/http"
	"strconv"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/storage"
)

// Scoped sync routes (C1, docs/designs/C1-sync-isolation.md). They sit beside
// the legacy GET /api/v1/sync/events and are registered only when the
// operator leaves ScopedSync on (the default; PRIVATE_MESSENGER_SCOPED_SYNC=0
// turns it off). The app uses the conversation route to pause one failing
// conversation (C1-P1). The
// handlers only parse, call the storage reads and shape the envelope.

const (
	syncScopeAccount      = "account"
	syncScopeConversation = "conversation"
)

func (a *API) registerScopedSyncRoutes(mux *http.ServeMux) {
	if !a.ScopedSync {
		return
	}
	mux.HandleFunc("GET /api/v1/sync/account-events", a.withAuth(a.accountSyncEvents))
	mux.HandleFunc("GET /api/v1/conversations/{id}/sync-events", a.withAuth(a.conversationSyncEvents))
}

func (a *API) accountSyncEvents(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	after, limit := syncPageParams(r)
	events, err := a.Store.ListAccountSyncEvents(r.Context(), principal.AccountID, principal.DeviceID, after, limit)
	a.writeScopedSync(w, r, principal, syncScopeAccount, principal.AccountID, events, err)
}

func (a *API) conversationSyncEvents(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	after, limit := syncPageParams(r)
	conversationID := r.PathValue("id")
	events, err := a.Store.ListConversationSyncEvents(r.Context(), principal.AccountID, principal.DeviceID, conversationID, after, limit)
	a.writeScopedSync(w, r, principal, syncScopeConversation, conversationID, events, err)
}

func syncPageParams(r *http.Request) (int64, int) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	return after, limit
}

// writeScopedSync writes the stream envelope. The bounds are the account's,
// as in the legacy stream, so a client must not read them as this scope's
// progress or floor; the expiry decision itself is made per scope in
// storage. A 409 pauses only this scope: the account scope keeps the
// device-wide device_recovery_required (missing account events stay a
// device-wide condition), a conversation scope answers
// conversation_recovery_required so a client never relinks the whole device
// over one paused conversation.
func (a *API) writeScopedSync(w http.ResponseWriter, r *http.Request, principal domain.Principal, scope, scopeID string, events []domain.SyncEvent, err error) {
	expired := errors.Is(err, storage.ErrSyncCursorExpired)
	if err != nil && !expired {
		if errors.Is(err, storage.ErrForbidden) || errors.Is(err, storage.ErrNotMember) {
			handleStorageError(w, err)
			return
		}
		writeError(w, http.StatusInternalServerError, "sync_events_failed")
		return
	}
	epoch, oldest, latest, boundsErr := a.Store.SyncBounds(r.Context(), principal.AccountID)
	if boundsErr != nil {
		writeError(w, http.StatusInternalServerError, "sync_events_failed")
		return
	}
	body := map[string]interface{}{"scope": scope, "scope_id": scopeID, "sync_epoch": epoch, "oldest_event_id": oldest, "latest_event_id": latest}
	if expired {
		body["error"] = "device_recovery_required"
		if scope == syncScopeConversation {
			body["error"] = "conversation_recovery_required"
		}
		writeJSON(w, http.StatusConflict, body)
		return
	}
	if events == nil {
		events = []domain.SyncEvent{}
	}
	body["events"] = events
	candidates := a.deliveryCandidates(r.Context(), principal.AccountID, events)
	writeJSON(w, http.StatusOK, body)
	a.recordDeliveredAsync(principal.AccountID, candidates)
}
