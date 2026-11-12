package httpapi

import (
	"net/http"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

// C3 channel conversion (C7 decision 11; docs/crypto.md, "C3 channel
// conversion"): the move itself, and the old conversation's bodies and
// signing keys for the members of the channel's new group.
func (a *API) registerChannelMoveRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/channels/{id}/move", a.withAuth(a.withWriteBudget(a.moveChannel)))
	mux.HandleFunc("GET /api/v1/channels/{id}/moves/{from}/history", a.withAuth(a.movedHistory))
	mux.HandleFunc("GET /api/v1/channels/{id}/moves/{from}/keys", a.withAuth(a.movedKeys))
}

func (a *API) moveChannel(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		AccessMode string `json:"access_mode"`
		// RequestID is the device's id for this move (22-128 base64url
		// characters). Only a request with the same id is answered as the
		// same move (review L-6); without one nothing replays.
		RequestID string `json:"request_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.RequestID != "" && !storage.ValidMoveRequestID(req.RequestID) {
		writeError(w, http.StatusBadRequest, "invalid_input")
		return
	}
	result, err := a.Store.MoveChannel(r.Context(), r.PathValue("id"), strings.TrimSpace(req.AccessMode), principal.AccountID, req.RequestID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	move := result.Move
	if result.Replayed {
		// Review L-6: the actor's own move again; its events went out then.
		writeJSON(w, http.StatusOK, map[string]interface{}{"move": move, "conversation": result.Conversation})
		return
	}
	now := time.Now().UTC()
	a.publishCommittedEvent(r.Context(), a.conversationMemberIDs(r.Context(), move.FromConversationID), realtime.Event{Version: "v1", Type: storage.ChannelMovedEventType, ID: result.FromEventID, ConversationID: move.FromConversationID, Payload: move, CreatedAt: now})
	a.publishCommittedEvent(r.Context(), a.conversationMemberIDs(r.Context(), move.ToConversationID), realtime.Event{Version: "v1", Type: storage.ChannelMovedEventType, ID: result.ToEventID, ConversationID: move.ToConversationID, Payload: move, CreatedAt: now})
	writeJSON(w, http.StatusOK, map[string]interface{}{"move": move, "conversation": result.Conversation})
}

func (a *API) movedHistory(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !a.C7History {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	query := r.URL.Query()
	bodies, err := a.Store.ListMovedHistoryBodies(r.Context(), principal.AccountID, principal.DeviceID, r.PathValue("id"), r.PathValue("from"),
		query.Get("stream"), strings.TrimSpace(query.Get("before")), messageQueryLimit(r))
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"history": bodies})
}

func (a *API) movedKeys(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !a.C7History {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	keys, err := a.Store.ListMovedMemberKeys(r.Context(), principal.AccountID, principal.DeviceID, r.PathValue("id"), r.PathValue("from"))
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"devices": keys})
}
