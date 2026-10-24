package httpapi

import (
	"net/http"
	"strconv"
	"strings"

	"private-messenger/server/internal/domain"
)

func requireAdministrator(w http.ResponseWriter, principal domain.Principal) bool {
	if !domain.CanManageInvites(principal.Role) {
		writeError(w, http.StatusForbidden, "forbidden")
		return false
	}
	return true
}

func (a *API) listAdminAccounts(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !requireAdministrator(w, principal) {
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	accounts, err := a.Store.ListAdminAccounts(r.Context(), limit, strings.TrimSpace(r.URL.Query().Get("after")))
	if err != nil {
		handleStorageError(w, err)
		return
	}
	response := map[string]interface{}{"accounts": accounts}
	if len(accounts) > 0 && len(accounts) == limit {
		response["next_after"] = accounts[len(accounts)-1].ID
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *API) setAdminAccountStatus(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !requireAdministrator(w, principal) {
		return
	}
	var req struct {
		Status string `json:"status"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	targetID := strings.TrimSpace(r.PathValue("id"))
	if err := a.Store.SetAccountStatus(r.Context(), principal.AccountID, targetID, req.Status); err != nil {
		handleStorageError(w, err)
		return
	}
	if req.Status == "suspended" {
		a.Hub.DisconnectAccount(targetID)
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.status.updated", map[string]string{"target_account_id": targetID, "status": req.Status})
	writeJSON(w, http.StatusOK, map[string]string{"account_id": targetID, "status": req.Status})
}

func (a *API) adminRevokeInvite(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !requireAdministrator(w, principal) {
		return
	}
	inviteID := strings.TrimSpace(r.PathValue("id"))
	if err := a.Store.AdminRevokeInvite(r.Context(), inviteID); err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "invite.revoked", map[string]string{"invite_id": inviteID})
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) listAdminAuditEvents(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !requireAdministrator(w, principal) {
		return
	}
	query := r.URL.Query()
	after, _ := strconv.ParseInt(query.Get("after"), 10, 64)
	before, _ := strconv.ParseInt(query.Get("before"), 10, 64)
	limit, _ := strconv.Atoi(query.Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	// order=desc lists newest first and pages with before; the default stays
	// oldest first and pages with after.
	newestFirst := query.Get("order") == "desc"
	events, err := a.Store.ListAdminAuditEvents(r.Context(), after, before, newestFirst, limit)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	response := map[string]interface{}{"events": events}
	if len(events) == limit && len(events) > 0 {
		if newestFirst {
			response["next_before"] = events[len(events)-1].ID
		} else {
			response["next_after"] = events[len(events)-1].ID
		}
	}
	writeJSON(w, http.StatusOK, response)
}
