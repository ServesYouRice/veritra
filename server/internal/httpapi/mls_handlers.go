package httpapi

import (
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

func (a *API) createMLSMessage(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	conversationID := strings.TrimSpace(r.PathValue("id"))
	var request struct {
		Kind               string `json:"kind"`
		RecipientDeviceID  string `json:"recipient_device_id,omitempty"`
		RevocationDeviceID string `json:"revocation_device_id,omitempty"`
		Payload            []byte `json:"payload"`
		IdempotencyKey     string `json:"idempotency_key"`
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 6<<20))
	if err != nil || !decodeRawJSON(w, raw, &request) {
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_body")
		}
		return
	}
	message, duplicate, err := a.Store.CreateMLSMessage(r.Context(), storage.CreateMLSMessageInput{
		ConversationID: conversationID, SenderAccountID: principal.AccountID,
		SenderDeviceID: principal.DeviceID, RecipientDeviceID: request.RecipientDeviceID,
		RevocationDeviceID: request.RevocationDeviceID,
		Kind:               request.Kind, Payload: request.Payload, IdempotencyKey: request.IdempotencyKey,
	})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if !duplicate {
		members, err := a.Store.ListConversationMembers(r.Context(), conversationID, principal.AccountID)
		if err == nil {
			accounts := make([]string, 0, len(members))
			for _, member := range members {
				accounts = append(accounts, member.AccountID)
			}
			a.publishCommittedEvent(accounts, realtime.Event{
				Version: "v1", Type: "mls.message.created", ID: message.SyncEventID,
				ConversationID: message.ConversationID,
				Payload:        map[string]string{"mls_message_id": message.ID, "kind": message.Kind},
				CreatedAt:      message.CreatedAt,
			})
		}
	}
	status := http.StatusCreated
	if duplicate {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{"mls_message": message})
}

func (a *API) listMLSRevocations(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	items, err := a.Store.ListMLSRevocations(r.Context(), principal.AccountID, principal.DeviceID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"mls_revocations": items})
}

func (a *API) confirmMLSRevocation(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	conversationID := strings.TrimSpace(r.PathValue("id"))
	revokedDeviceID := strings.TrimSpace(r.PathValue("device_id"))
	eventID, err := a.Store.ConfirmMLSRevocation(r.Context(), conversationID, revokedDeviceID, principal.AccountID, principal.DeviceID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if eventID > 0 {
		members, err := a.Store.ListConversationMembers(r.Context(), conversationID, principal.AccountID)
		if err == nil {
			accounts := make([]string, 0, len(members))
			for _, member := range members {
				accounts = append(accounts, member.AccountID)
			}
			a.publishCommittedEvent(accounts, realtime.Event{Version: "v1", Type: "mls.revocation.completed", ID: eventID,
				ConversationID: conversationID, Payload: map[string]string{"device_id": revokedDeviceID}, CreatedAt: time.Now().UTC()})
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) getMLSMessage(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	message, err := a.Store.MLSMessage(r.Context(), strings.TrimSpace(r.PathValue("id")), principal.AccountID, principal.DeviceID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"mls_message": message})
}

func (a *API) listMLSMessages(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if after < 0 {
		writeError(w, http.StatusBadRequest, "invalid_cursor")
		return
	}
	messages, err := a.Store.ListMLSMessages(r.Context(), principal.AccountID, principal.DeviceID, after, limit)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"mls_messages": messages,
		"server_time":  time.Now().UTC(),
	})
}
