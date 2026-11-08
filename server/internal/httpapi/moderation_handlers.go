package httpapi

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

// moderationRoute serves C5 under /api/v1/communities/{id}/... and reports
// whether it handled the request:
//
//	POST   {id}/members/{account}/kick
//	POST   {id}/bans                      {account_id}
//	GET    {id}/bans
//	DELETE {id}/bans/{account}
//	PUT    {id}/members/{account}/timeout {seconds}   (0 clears)
//	PUT    {id}/channels/{channel}/slow-mode {seconds} (0 turns off)
//	PUT    {id}/invites-pause             {seconds}   (0 resumes)
//	GET    {id}/moderation-events
func (a *API) moderationRoute(w http.ResponseWriter, r *http.Request, principal domain.Principal, parts []string) bool {
	community := parts[0]
	switch {
	case len(parts) == 4 && parts[1] == "members" && parts[3] == "kick" && r.Method == http.MethodPost:
		target, ok := moderationTarget(w, parts[2])
		if !ok {
			return true
		}
		removal, err := a.Store.KickCommunityMember(r.Context(), community, principal.AccountID, target)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		a.publishCommunityRemoval(r, community, target, "membership.removed", removal)
		a.recordAuditEvent(r.Context(), &principal.AccountID, "community.member.kicked", map[string]string{"community_id": community})
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "membership_removed", "mls_coordination": "pending", "channels": removalChannels(removal)})
	case len(parts) == 2 && parts[1] == "bans" && r.Method == http.MethodPost:
		var req struct {
			AccountID string `json:"account_id"`
		}
		if !decodeJSON(w, r, &req) {
			return true
		}
		target, ok := moderationTarget(w, req.AccountID)
		if !ok {
			return true
		}
		removal, err := a.Store.BanCommunityMember(r.Context(), community, principal.AccountID, target)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		a.publishCommunityRemoval(r, community, target, "membership.removed", removal)
		a.recordAuditEvent(r.Context(), &principal.AccountID, "community.member.banned", map[string]string{"community_id": community})
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "banned", "mls_coordination": "pending", "channels": removalChannels(removal)})
	case len(parts) == 2 && parts[1] == "bans" && r.Method == http.MethodGet:
		bans, err := a.Store.ListCommunityBans(r.Context(), community, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"bans": bans})
	case len(parts) == 3 && parts[1] == "bans" && r.Method == http.MethodDelete:
		target, ok := moderationTarget(w, parts[2])
		if !ok {
			return true
		}
		if err := a.Store.UnbanCommunityMember(r.Context(), community, principal.AccountID, target); err != nil {
			handleStorageError(w, err)
			return true
		}
		a.recordAuditEvent(r.Context(), &principal.AccountID, "community.member.unbanned", map[string]string{"community_id": community})
		writeJSON(w, http.StatusOK, map[string]string{"status": "unbanned"})
	case len(parts) == 4 && parts[1] == "members" && parts[3] == "timeout" && r.Method == http.MethodPut:
		target, ok := moderationTarget(w, parts[2])
		if !ok {
			return true
		}
		d, ok := secondsBody(w, r)
		if !ok {
			return true
		}
		until, err := a.Store.SetMemberTimeout(r.Context(), community, principal.AccountID, target, d)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "ok", "timeout_until": until})
	case len(parts) == 4 && parts[1] == "channels" && parts[3] == "slow-mode" && r.Method == http.MethodPut:
		d, ok := secondsBody(w, r)
		if !ok {
			return true
		}
		if err := a.Store.SetChannelSlowMode(r.Context(), community, parts[2], principal.AccountID, d); err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "ok", "slow_mode_seconds": int64(d / time.Second)})
	case len(parts) == 2 && parts[1] == "invites-pause" && r.Method == http.MethodPut:
		d, ok := secondsBody(w, r)
		if !ok {
			return true
		}
		until, err := a.Store.SetInvitesPaused(r.Context(), community, principal.AccountID, d)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "ok", "invites_paused_until": until})
	case len(parts) == 2 && parts[1] == "moderation-state" && r.Method == http.MethodGet:
		state, err := a.Store.GetModerationState(r.Context(), community, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, state)
	case len(parts) == 2 && parts[1] == "moderation-events" && r.Method == http.MethodGet:
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		events, err := a.Store.ListModerationEvents(r.Context(), community, principal.AccountID, limit)
		if err != nil {
			handleStorageError(w, err)
			return true
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"events": events})
	default:
		return false
	}
	return true
}

func moderationTarget(w http.ResponseWriter, raw string) (string, bool) {
	target := strings.TrimSpace(raw)
	if !domain.ValidID("acct", target) {
		writeError(w, http.StatusBadRequest, "invalid_account_id")
		return "", false
	}
	return target, true
}

func secondsBody(w http.ResponseWriter, r *http.Request) (time.Duration, bool) {
	var req struct {
		Seconds int64 `json:"seconds"`
	}
	if !decodeJSON(w, r, &req) {
		return 0, false
	}
	// Bounded here so the multiplication cannot overflow; the store applies
	// the real limits.
	if req.Seconds < 0 || req.Seconds > 365*24*3600 {
		writeError(w, http.StatusBadRequest, "invalid_seconds")
		return 0, false
	}
	return time.Duration(req.Seconds) * time.Second, true
}

// publishCommunityRemoval tells the remaining members of each channel and the
// removed account, as a leave or removal does, so their apps reconcile MLS.
func (a *API) publishCommunityRemoval(r *http.Request, communityID, target, eventType string, removal storage.CommunityRemoval) {
	for _, channel := range removal.Channels {
		payload := map[string]string{"conversation_id": channel.ConversationID, "community_id": communityID, "account_id": target, "mls_coordination": "pending"}
		a.publishCommittedEvent(r.Context(), a.conversationMemberIDs(r.Context(), channel.ConversationID), realtime.Event{Version: "v1", Type: eventType, ID: channel.RemainingMembersEventID, ConversationID: channel.ConversationID, Payload: payload, CreatedAt: time.Now().UTC()})
		a.publishCommittedEvent(r.Context(), []string{target}, realtime.Event{Version: "v1", Type: eventType, ID: channel.RemovedMemberEventID, ConversationID: channel.ConversationID, Payload: payload, CreatedAt: time.Now().UTC()})
	}
}

// removalChannels is the per-channel part of a removal response, the same
// shape as DELETE /communities/{id}/members/{account}.
func removalChannels(removal storage.CommunityRemoval) []map[string]interface{} {
	channels := make([]map[string]interface{}, 0, len(removal.Channels))
	for _, channel := range removal.Channels {
		channels = append(channels, map[string]interface{}{"conversation_id": channel.ConversationID, "event_id": channel.RemovedMemberEventID})
	}
	return channels
}
