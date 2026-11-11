package httpapi

import (
	"net/http"
	"strings"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/storage"
)

// C4 server succession (docs/designs/C4-custom-roles.md, "Server
// succession"): after an election is won in a group's signed role record, the
// members' apps ask the server to move its owner row too.
//
//	POST /api/v1/conversations/{id}/owner-succession {candidate_account_id}
//	POST /api/v1/communities/{id}/owner-succession   {candidate_account_id}
//
// 200 {"status": "moved"} when the candidate is now the server's owner, or
// {"status": "recorded"} when the ask is kept until the rule holds (the owner
// quiet for 37 days and a majority of admins asking). Apps never read the
// owner row for roles; this only lets the server's own checks follow.
func (a *API) registerSuccessionRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/conversations/{id}/owner-succession", a.withAuth(a.withWriteBudget(a.conversationSuccession)))
	mux.HandleFunc("POST /api/v1/communities/{id}/owner-succession", a.withAuth(a.withWriteBudget(a.communitySuccession)))
}

func (a *API) conversationSuccession(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.ownerSuccession(w, r, principal, false)
}

func (a *API) communitySuccession(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.ownerSuccession(w, r, principal, true)
}

func (a *API) ownerSuccession(w http.ResponseWriter, r *http.Request, principal domain.Principal, community bool) {
	var req struct {
		CandidateAccountID string `json:"candidate_account_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	candidate, ok := moderationTarget(w, req.CandidateAccountID)
	if !ok {
		return
	}
	scope := strings.TrimSpace(r.PathValue("id"))
	var (
		status storage.SuccessionStatus
		err    error
	)
	if community {
		status, _, err = a.Store.RequestCommunitySuccession(r.Context(), scope, principal.AccountID, candidate)
	} else {
		status, _, err = a.Store.RequestConversationSuccession(r.Context(), scope, principal.AccountID, candidate)
	}
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if status == storage.SuccessionMoved {
		key, kind := "conversation_id", "conversation.owner.succeeded"
		if community {
			key, kind = "community_id", "community.owner.succeeded"
		}
		a.recordAuditEvent(r.Context(), &principal.AccountID, kind, map[string]string{key: scope})
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": string(status)})
}
