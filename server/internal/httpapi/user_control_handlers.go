package httpapi

import (
	"net/http"
	"strings"

	"private-messenger/server/internal/domain"
)

func (a *API) listAccountBlocks(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	blocks, err := a.Store.ListBlockedAccounts(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"blocks": blocks})
}

func (a *API) blockAccount(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	targetID := strings.TrimSpace(r.PathValue("id"))
	block, err := a.Store.BlockAccount(r.Context(), principal.AccountID, targetID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.blocked", map[string]string{"target_account_id": targetID})
	writeJSON(w, http.StatusOK, block)
}

func (a *API) unblockAccount(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	targetID := strings.TrimSpace(r.PathValue("id"))
	if err := a.Store.UnblockAccount(r.Context(), principal.AccountID, targetID); err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.unblocked", map[string]string{"target_account_id": targetID})
	w.WriteHeader(http.StatusNoContent)
}
