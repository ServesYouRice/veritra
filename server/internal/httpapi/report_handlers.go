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
// sealed ciphertext and nothing about the reported message: since D95 the
// envelope id is sealed inside the report, never sent in clear. It never opens
// a report, never logs one, and its audit entries hold ids and kinds only.

// PUT /api/v1/reports/inbox-keys/instance: an instance owner publishes their
// own report public key (one sealed copy per owner, D95).
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
	recipient, err := a.Store.SetInstanceReportKey(r.Context(), principal.AccountID, req.PublicKey)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "report.inbox_key.updated", map[string]interface{}{"inbox_kind": franking.InboxInstanceOwner, "key_rev": recipient.KeyRev})
	writeJSON(w, http.StatusOK, recipient)
}

// GET /api/v1/reports/inbox-keys/instance: the calling owner's own current
// report key (404 when none is published), so a device that lost the race to
// another device can show the key reporters actually see.
func (a *API) getInstanceReportKey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	recipient, err := a.Store.InstanceReportKey(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, recipient)
}

// PUT /api/v1/reports/inbox-keys/community/{community_id}: a community member
// publishes their own report public key as their moderator inbox there (C6,
// one sealed copy per moderator). Reporters' apps seal to it only when their
// verified role record ranks this account moderator or above.
func (a *API) putCommunityReportKey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
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
	communityID := strings.TrimSpace(r.PathValue("community_id"))
	recipient, err := a.Store.SetCommunityReportKey(r.Context(), communityID, principal.AccountID, req.PublicKey)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "report.inbox_key.updated", map[string]interface{}{"inbox_kind": franking.InboxCommunity, "key_rev": recipient.KeyRev})
	writeJSON(w, http.StatusOK, recipient)
}

// GET /api/v1/reports/inbox-keys/community/{community_id}: the caller's own
// moderator key there (404 when none is published).
func (a *API) getCommunityReportKey(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	recipient, err := a.Store.CommunityReportKey(r.Context(), strings.TrimSpace(r.PathValue("community_id")), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, recipient)
}

// GET /api/v1/reports/inbox?conversation_id=: where a report about a message
// of this conversation goes, and the keys to seal one copy to each recipient.
// Members only.
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

// POST /api/v1/reports: file a sealed report. The reporter sends the
// conversation, a report id its app chose, and one sealed copy per recipient
// with the key and revision that copy was sealed to. The envelope id and the
// revealed message are inside the sealed bytes; the server picks the inbox,
// checks that the copies match its recipients, and learns nothing else.
func (a *API) createReport(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		ConversationID string `json:"conversation_id"`
		ReportID       string `json:"report_id"`
		Copies         []struct {
			InboxID      string `json:"inbox_id"`
			KeyRev       int64  `json:"key_rev"`
			RecipientKey []byte `json:"recipient_public_key"`
			Sealed       []byte `json:"sealed"`
		} `json:"copies"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ConversationID == "" || len(req.ConversationID) > franking.MaxIDSize || req.ReportID == "" || len(req.ReportID) > franking.MaxIDSize || len(req.Copies) == 0 {
		writeError(w, http.StatusBadRequest, "invalid_report")
		return
	}
	input := storage.CreateReportInput{ReporterAccountID: principal.AccountID, ConversationID: req.ConversationID, ReportID: req.ReportID}
	for _, c := range req.Copies {
		input.Copies = append(input.Copies, storage.ReportCopyInput{InboxID: c.InboxID, KeyRev: c.KeyRev, RecipientKey: c.RecipientKey, Sealed: c.Sealed})
	}
	reports, err := a.Store.CreateReport(r.Context(), input)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "report.filed", map[string]interface{}{"inbox_kind": reports[0].InboxKind, "copies": len(reports)})
	// The reporter already holds the sealed bytes.
	writeJSON(w, http.StatusCreated, map[string]interface{}{"report_id": req.ReportID, "copies": len(reports), "created_at": reports[0].CreatedAt})
}

// GET /api/v1/reports?inbox=instance_owner, or ?inbox=community&community_id=:
// the sealed reports of an inbox the caller may read: always the caller's own
// (for a community, the caller's moderator inbox there).
func (a *API) listReports(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	query := r.URL.Query()
	kind, inboxID := strings.TrimSpace(query.Get("inbox")), principal.AccountID
	switch kind {
	case franking.InboxInstanceOwner:
	case franking.InboxCommunity:
		communityID := strings.TrimSpace(query.Get("community_id"))
		if communityID == "" {
			writeError(w, http.StatusBadRequest, "community_id_required")
			return
		}
		inboxID = franking.CommunityModeratorInboxID(communityID, principal.AccountID)
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

// DELETE /api/v1/reports/{id}: dismiss a report copy from an inbox the caller
// may read.
func (a *API) deleteReport(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	report, err := a.Store.DeleteReport(r.Context(), principal.AccountID, strings.TrimSpace(r.PathValue("id")))
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "report.dismissed", map[string]interface{}{"inbox_kind": report.InboxKind})
	w.WriteHeader(http.StatusNoContent)
}

// GET /api/v1/reports/{id}/envelope?envelope_id=: the sender, time and
// franking commitment the server recorded for a message of the conversation
// copy {id} was filed about, so its recipient can verify the report (G1). The
// envelope id comes from the opened report; the server sees it only now, from
// the recipient. Nothing is written or logged.
func (a *API) getReportEnvelope(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	envelopeID := strings.TrimSpace(r.URL.Query().Get("envelope_id"))
	if envelopeID == "" || len(envelopeID) > franking.MaxIDSize {
		writeError(w, http.StatusBadRequest, "invalid_report")
		return
	}
	record, err := a.Store.ReportEnvelopeRecord(r.Context(), principal.AccountID, strings.TrimSpace(r.PathValue("id")), envelopeID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, record)
}
