package httpapi

import (
	"net/http"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

// C1 membership invitations and join requests. The invitation secret stays in
// the link's fragment; clients send only a locator derived from it, in a
// request body (never a path or query). Handlers record only invitation and
// request ids, never the locator.

const defaultMembershipInviteLifetime = 7 * 24 * time.Hour

func (a *API) registerMembershipInviteRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/membership-invites/preview", a.withAuth(a.previewMembershipInvite))
	mux.HandleFunc("POST /api/v1/membership-invites/requests", a.withAuth(a.withWriteBudget(a.requestToJoin)))
	mux.HandleFunc("DELETE /api/v1/membership-invites/{id}", a.withAuth(a.withWriteBudget(a.revokeMembershipInvite)))
	mux.HandleFunc("GET /api/v1/join-requests", a.withAuth(a.listOwnJoinRequests))
	mux.HandleFunc("POST /api/v1/join-requests/{id}/approve", a.withAuth(a.withWriteBudget(a.approveJoinRequest)))
	mux.HandleFunc("POST /api/v1/join-requests/{id}/reject", a.withAuth(a.withWriteBudget(a.rejectJoinRequest)))
	mux.HandleFunc("DELETE /api/v1/join-requests/{id}", a.withAuth(a.withWriteBudget(a.cancelJoinRequest)))
}

type locatorRequest struct {
	Locator string `json:"locator"`
}

type createMembershipInviteRequest struct {
	Locator string `json:"locator"`
	// SigningKey and BindingTag are what the app bound the invitation to
	// (D90). The device is the session's, never a field of the request.
	SigningKey       []byte `json:"signing_key"`
	BindingTag       string `json:"binding_tag"`
	MaxUses          int    `json:"max_uses"`
	ExpiresInSeconds int64  `json:"expires_in_seconds"`
}

// membershipTargetRoute serves /{id}/invites and /{id}/join-requests of a
// community or group, and a community's member removal. It reports whether the
// request was one of those.
func (a *API) membershipTargetRoute(w http.ResponseWriter, r *http.Request, principal domain.Principal, kind string, parts []string) bool {
	if len(parts) != 2 || parts[0] == "" {
		return false
	}
	target := storage.MembershipTarget{Kind: kind, ID: parts[0]}
	switch {
	case parts[1] == "invites" && r.Method == http.MethodPost:
		a.createMembershipInvite(w, r, principal, target)
	case parts[1] == "invites" && r.Method == http.MethodGet:
		invites, err := a.Store.ListMembershipInvites(r.Context(), target, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"invites": invites})
	case parts[1] == "join-requests" && r.Method == http.MethodGet:
		requests, err := a.Store.ListJoinRequests(r.Context(), target, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"requests": requests})
	default:
		return false
	}
	return true
}

func (a *API) createMembershipInvite(w http.ResponseWriter, r *http.Request, principal domain.Principal, target storage.MembershipTarget) {
	var req createMembershipInviteRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.MaxUses == 0 {
		req.MaxUses = 1
	}
	lifetime := defaultMembershipInviteLifetime
	if req.ExpiresInSeconds != 0 {
		if req.ExpiresInSeconds < 0 || req.ExpiresInSeconds > int64(storage.MaxMembershipInviteLifetime/time.Second) {
			writeError(w, http.StatusBadRequest, "invalid_expires_in")
			return
		}
		lifetime = time.Duration(req.ExpiresInSeconds) * time.Second
	}
	if principal.DeviceID == "" {
		// A session without a device has no key to bind the invitation to.
		writeError(w, http.StatusBadRequest, "invalid_input")
		return
	}
	invite, err := a.Store.CreateMembershipInvite(r.Context(), storage.CreateMembershipInviteInput{
		Target:            target,
		CreatedBy:         principal.AccountID,
		CreatedByDeviceID: principal.DeviceID,
		SigningKey:        req.SigningKey,
		BindingTag:        req.BindingTag,
		Locator:           req.Locator,
		MaxUses:           req.MaxUses,
		ExpiresAt:         time.Now().UTC().Add(lifetime),
	})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "membership.invite.created", map[string]interface{}{"invite_id": invite.ID, "target_kind": target.Kind, "target_id": target.ID, "max_uses": invite.MaxUses})
	writeJSON(w, http.StatusCreated, invite)
}

func (a *API) revokeMembershipInvite(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	inviteID := strings.TrimSpace(r.PathValue("id"))
	if inviteID == "" {
		writeError(w, http.StatusBadRequest, "invalid_invite_id")
		return
	}
	if err := a.Store.RevokeMembershipInvite(r.Context(), principal.AccountID, inviteID); err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "membership.invite.revoked", map[string]string{"invite_id": inviteID})
	writeJSON(w, http.StatusOK, map[string]string{"status": "revoked"})
}

func (a *API) previewMembershipInvite(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req locatorRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	preview, err := a.Store.PreviewMembershipInvite(r.Context(), principal.AccountID, req.Locator)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, preview)
}

func (a *API) requestToJoin(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req locatorRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	request, created, err := a.Store.RequestToJoin(r.Context(), principal.AccountID, req.Locator)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
		a.recordAuditEvent(r.Context(), &principal.AccountID, "membership.join_request.created", map[string]string{"request_id": request.ID})
	}
	writeJSON(w, status, request)
}

func (a *API) listOwnJoinRequests(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	requests, err := a.Store.ListOwnJoinRequests(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"requests": requests})
}

func (a *API) cancelJoinRequest(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if err := a.Store.CancelJoinRequest(r.Context(), principal.AccountID, strings.TrimSpace(r.PathValue("id"))); err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": domain.JoinRequestCancelled})
}

func (a *API) approveJoinRequest(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.decideJoinRequest(w, r, principal, true)
}

func (a *API) rejectJoinRequest(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.decideJoinRequest(w, r, principal, false)
}

func (a *API) decideJoinRequest(w http.ResponseWriter, r *http.Request, principal domain.Principal, approve bool) {
	requestID := strings.TrimSpace(r.PathValue("id"))
	decision, err := a.Store.DecideJoinRequest(r.Context(), principal.AccountID, requestID, approve)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	response := map[string]interface{}{"status": decision.Request.Status, "request": decision.Request}
	if decision.Changed && approve {
		// Membership is recorded; encrypted access follows through the
		// existing staged MLS coordination, which the apps start from the event.
		response["mls_coordination"] = "pending"
		if decision.ConversationID != "" {
			payload := map[string]string{"conversation_id": decision.ConversationID, "account_id": decision.Request.AccountID, "role": domain.RoleMember, "mls_coordination": "pending"}
			a.publishCommittedEvent(r.Context(), a.conversationMemberIDs(r.Context(), decision.ConversationID), realtime.Event{Version: "v1", Type: "membership.updated", ID: decision.EventID, ConversationID: decision.ConversationID, Payload: payload, CreatedAt: time.Now().UTC()})
		}
	}
	if decision.Changed {
		eventType := "membership.join_request.rejected"
		if approve {
			eventType = "membership.join_request.approved"
		}
		a.recordAuditEvent(r.Context(), &principal.AccountID, eventType, map[string]string{"request_id": requestID, "target_kind": decision.Request.TargetKind, "target_id": decision.Request.TargetID})
	}
	writeJSON(w, http.StatusOK, response)
}

// removeCommunityMember serves DELETE /communities/{id}/members/{account|me}.
func (a *API) removeCommunityMember(w http.ResponseWriter, r *http.Request, principal domain.Principal, communityID, accountParam string) {
	targetAccountID := strings.TrimSpace(accountParam)
	if targetAccountID == "me" {
		targetAccountID = principal.AccountID
	}
	if !domain.ValidID("acct", targetAccountID) {
		writeError(w, http.StatusBadRequest, "invalid_account_id")
		return
	}
	removal, err := a.Store.RemoveCommunityMember(r.Context(), communityID, principal.AccountID, targetAccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	eventType := "membership.removed"
	if targetAccountID == principal.AccountID {
		eventType = "membership.left"
	}
	channels := make([]map[string]interface{}, 0, len(removal.Channels))
	for _, channel := range removal.Channels {
		payload := map[string]string{"conversation_id": channel.ConversationID, "community_id": communityID, "account_id": targetAccountID, "mls_coordination": "pending"}
		a.publishCommittedEvent(r.Context(), a.conversationMemberIDs(r.Context(), channel.ConversationID), realtime.Event{Version: "v1", Type: eventType, ID: channel.RemainingMembersEventID, ConversationID: channel.ConversationID, Payload: payload, CreatedAt: time.Now().UTC()})
		a.publishCommittedEvent(r.Context(), []string{targetAccountID}, realtime.Event{Version: "v1", Type: eventType, ID: channel.RemovedMemberEventID, ConversationID: channel.ConversationID, Payload: payload, CreatedAt: time.Now().UTC()})
		channels = append(channels, map[string]interface{}{"conversation_id": channel.ConversationID, "event_id": channel.RemovedMemberEventID})
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "community.member.removed", map[string]string{"community_id": communityID})
	writeJSON(w, http.StatusOK, map[string]interface{}{"status": "membership_removed", "mls_coordination": "pending", "channels": channels})
}
