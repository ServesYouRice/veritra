package httpapi

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

func (a *API) createCall(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		ConversationID string          `json:"conversation_id"`
		Metadata       json.RawMessage `json:"metadata,omitempty"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validCallMetadata(req.Metadata) {
		writeError(w, http.StatusBadRequest, "invalid_call_metadata")
		return
	}
	call, err := a.Store.CreateCallSession(r.Context(), req.ConversationID, principal.AccountID, req.Metadata)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	eventID := a.saveSyncEvent(r.Context(), "call.signaling", nil, req.ConversationID, call)
	members := a.conversationRecipientsForSender(r.Context(), req.ConversationID, principal.AccountID)
	a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "call.signaling", ID: eventID, ConversationID: req.ConversationID, Payload: call, CreatedAt: time.Now().UTC()})
	writeJSON(w, http.StatusCreated, call)
}

func (a *API) listCalls(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	conversationID := strings.TrimSpace(r.URL.Query().Get("conversation_id"))
	if conversationID == "" {
		writeError(w, http.StatusBadRequest, "conversation_id_required")
		return
	}
	calls, err := a.Store.ListCallSessions(r.Context(), conversationID, principal.AccountID, 100)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"calls": calls})
}

func (a *API) callSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/calls/"), "/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] != "state" || r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	var req struct {
		State    string          `json:"state"`
		Metadata json.RawMessage `json:"metadata,omitempty"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Metadata) > 0 && !validCallMetadata(req.Metadata) {
		writeError(w, http.StatusBadRequest, "invalid_call_metadata")
		return
	}
	call, err := a.Store.TransitionCallSession(r.Context(), parts[0], principal.AccountID, req.State, req.Metadata)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	eventID := a.saveSyncEvent(r.Context(), "call.state", nil, call.ConversationID, call)
	members := a.conversationRecipientsForSender(r.Context(), call.ConversationID, principal.AccountID)
	a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "call.state", ID: eventID, ConversationID: call.ConversationID, Payload: call, CreatedAt: time.Now().UTC()})
	writeJSON(w, http.StatusOK, call)
}

func validCallMetadata(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	if len(raw) > 64<<10 || containsPlaintextMessageKey(raw) {
		return false
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || len(fields) != 3 {
		return false
	}
	for _, name := range []string{"version", "ciphertext", "protocol"} {
		if _, ok := fields[name]; !ok {
			return false
		}
	}
	var envelope struct {
		Version    int    `json:"version"`
		Ciphertext []byte `json:"ciphertext"`
		Protocol   string `json:"protocol"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return false
	}
	return envelope.Version == 1 &&
		len(envelope.Ciphertext) > 0 &&
		len(envelope.Ciphertext) <= 48<<10 &&
		envelope.Protocol == "mls10-openmls-v1"
}

func (a *API) syncEvents(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	events, err := a.Store.ListSyncEvents(r.Context(), principal.AccountID, after, limit)
	if err != nil {
		if errors.Is(err, storage.ErrSyncCursorExpired) {
			epoch, oldest, latest, boundsErr := a.Store.SyncBounds(r.Context(), principal.AccountID)
			if boundsErr != nil {
				writeError(w, http.StatusInternalServerError, "sync_events_failed")
				return
			}
			writeJSON(w, http.StatusConflict, map[string]interface{}{"error": "full_resync_required", "sync_epoch": epoch, "oldest_event_id": oldest, "latest_event_id": latest})
			return
		}
		writeError(w, http.StatusInternalServerError, "sync_events_failed")
		return
	}
	epoch, oldest, latest, err := a.Store.SyncBounds(r.Context(), principal.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "sync_events_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"events": events, "sync_epoch": epoch, "oldest_event_id": oldest, "latest_event_id": latest})
}

func (a *API) searchMetadata(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	results, err := a.Store.SearchMetadata(r.Context(), principal.AccountID, r.URL.Query().Get("q"), limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_failed")
		return
	}
	normalizedLimit := normalizeLimit(limit, 20, 50)
	normalizedOffset := normalizeOffset(offset)
	response := map[string]interface{}{
		"results": results,
		"limit":   normalizedLimit,
		"offset":  normalizedOffset,
	}
	if len(results) == normalizedLimit {
		response["next_offset"] = normalizedOffset + len(results)
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *API) exportAccount(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit := normalizeLimit(messageQueryLimit(r), 1000, 5000)
	before := strings.TrimSpace(r.URL.Query().Get("before"))
	export, err := a.Store.ExportAccount(r.Context(), principal.AccountID, storage.ExportAccountOptions{Limit: limit, BeforeID: before})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	response := map[string]interface{}{
		"manifest_version": export.ManifestVersion,
		"account":          export.Account,
		"devices":          export.Devices,
		"conversations":    export.Conversations,
		"messages":         export.Messages,
		"categories":       export.Categories,
		"limit":            limit,
	}
	// Surface truncation explicitly so the client knows there may be more.
	if len(export.Messages) == limit && len(export.Messages) > 0 {
		response["next_before"] = export.Messages[len(export.Messages)-1].ID
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *API) deleteAccount(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	storageKeys, err := a.Store.DeleteAccountData(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	var blobDeleteFailures int
	for _, storageKey := range storageKeys {
		if err := a.Blobs.Delete(r.Context(), storageKey); err != nil {
			blobDeleteFailures++
		}
	}
	if blobDeleteFailures > 0 {
		a.Log.Error("account_blob_cleanup_incomplete", "failed_count", blobDeleteFailures)
	}
	a.Hub.DisconnectAccount(principal.AccountID)
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.deleted", nil)
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) syncWebSocket(w http.ResponseWriter, r *http.Request) {
	principal, err := a.principalFromRequest(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	remoteIP := strings.TrimSpace(r.RemoteAddr)
	if host, _, splitErr := net.SplitHostPort(r.RemoteAddr); splitErr == nil {
		remoteIP = host
	}
	client, err := a.Hub.Register(principal.AccountID, principal.DeviceID, remoteIP)
	if err != nil {
		writeError(w, http.StatusTooManyRequests, "realtime_connection_limit")
		return
	}
	_ = realtime.ServeWebSocket(w, r, client, principal.ExpiresAt, func() { a.Hub.Unregister(client) })
}

type authedHandler func(http.ResponseWriter, *http.Request, domain.Principal)
