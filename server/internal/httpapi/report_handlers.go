package httpapi

import (
	"net/http"
	"strconv"
	"strings"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/franking"
	"private-messenger/server/internal/storage"
)

// C6 report routes (docs/designs/C6-reports-franking.md). The server carries
// sealed ciphertext and the metadata it records itself. It never opens a
// report, never logs one, and its audit entries hold ids and kinds only.

// PUT /api/v1/reports/inbox-keys/instance: an instance owner publishes the
// owners' report public key.
func (a *API) putInstanceReportKey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		PublicKey []byte `json:"public_key"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.PublicKey) != franking.PublicKeySize {
		writeError(w, http.StatusBadRequest, "invalid_public_key")
		return
	}
	inbox, err := a.Store.SetInstanceReportKey(r.Context(), principal.AccountID, req.PublicKey)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "report.inbox_key.updated", map[string]interface{}{"inbox_kind": inbox.Kind, "key_rev": inbox.KeyRev})
	writeJSON(w, http.StatusOK, inbox)
}

// GET /api/v1/reports/inbox?conversation_id=: where a report about a message
// of this conversation goes, and the key to seal it to. Members only.
func (a *API) getReportInbox(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	conversationID := strings.TrimSpace(r.URL.Query().Get("conversation_id"))
	if conversationID == "" {
		writeError(w, http.StatusBadRequest, "conversation_id_required")
		return
	}
	inbox, err := a.Store.ReportInboxForConversation(r.Context(), conversationID, principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, inbox)
}

// POST /api/v1/reports: file a sealed report. The reporter sends only the
// conversation, the envelope, the key (and its revision) it sealed to, and the
// sealed bytes. The server picks the inbox and records the sender, commitment and
// envelope time from its own envelope row.
func (a *API) createReport(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		ConversationID string `json:"conversation_id"`
		EnvelopeID     string `json:"envelope_id"`
		KeyRev         int64  `json:"key_rev"`
		RecipientKey   []byte `json:"recipient_public_key"`
		Sealed         []byte `json:"sealed"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ConversationID == "" || req.EnvelopeID == "" || len(req.ConversationID) > franking.MaxIDSize || len(req.EnvelopeID) > franking.MaxIDSize || req.KeyRev < 1 || len(req.RecipientKey) != franking.PublicKeySize || len(req.Sealed) == 0 {
		writeError(w, http.StatusBadRequest, "invalid_report")
		return
	}
	report, err := a.Store.CreateReport(r.Context(), storage.CreateReportInput{ReporterAccountID: principal.AccountID, ConversationID: req.ConversationID, EnvelopeID: req.EnvelopeID, KeyRev: req.KeyRev, RecipientKey: req.RecipientKey, Sealed: req.Sealed})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "report.filed", map[string]interface{}{"report_id": report.ID, "inbox_kind": report.InboxKind})
	// The reporter already holds the sealed bytes.
	report.Sealed = nil
	writeJSON(w, http.StatusCreated, report)
}

// GET /api/v1/reports?inbox=instance_owner, or ?inbox=community&community_id=:
// the sealed reports of an inbox the caller may read.
func (a *API) listReports(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	query := r.URL.Query()
	kind, inboxID := strings.TrimSpace(query.Get("inbox")), franking.InstanceInboxID
	switch kind {
	case franking.InboxInstanceOwner:
	case franking.InboxCommunity:
		inboxID = strings.TrimSpace(query.Get("community_id"))
		if inboxID == "" {
			writeError(w, http.StatusBadRequest, "community_id_required")
			return
		}
	default:
		writeError(w, http.StatusBadRequest, "invalid_inbox")
		return
	}
	limit := 0
	if raw := query.Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 {
			writeError(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = parsed
	}
	reports, err := a.Store.ListReports(r.Context(), principal.AccountID, kind, inboxID, strings.TrimSpace(query.Get("after_id")), limit)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"reports": reports})
}

// DELETE /api/v1/reports/{id}: dismiss a report from an inbox the caller may
// read.
func (a *API) deleteReport(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	report, err := a.Store.DeleteReport(r.Context(), principal.AccountID, strings.TrimSpace(r.PathValue("id")))
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "report.dismissed", map[string]interface{}{"report_id": report.ID, "inbox_kind": report.InboxKind})
	w.WriteHeader(http.StatusNoContent)
}
