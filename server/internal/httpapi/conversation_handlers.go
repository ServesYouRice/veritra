package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/messaging"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

func (a *API) createCommunity(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req createCommunityRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validDisplayName(req.Name) {
		writeError(w, http.StatusBadRequest, "invalid_name")
		return
	}
	community, err := a.Store.CreateCommunity(r.Context(), req.Name, principal.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "community_create_failed")
		return
	}
	writeJSON(w, http.StatusCreated, community)
}

func (a *API) listCommunities(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	communities, err := a.Store.ListCommunities(r.Context(), principal.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "communities_list_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"communities": communities})
}

func (a *API) communitySubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/v1/communities/"), "/")
	if len(parts) == 2 && parts[1] == "members" && r.Method == http.MethodGet {
		members, err := a.Store.ListCommunityMembers(r.Context(), parts[0], principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"members": members})
		return
	}
	if len(parts) == 2 && parts[1] == "members" && r.Method == http.MethodPost {
		var req struct {
			AccountID string `json:"account_id"`
			Role      string `json:"role"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if req.Role == "" {
			req.Role = domain.RoleMember
		}
		if strings.TrimSpace(req.AccountID) == "" || !domain.ValidRole(req.Role) {
			writeError(w, http.StatusBadRequest, "invalid_member")
			return
		}
		if _, err := a.Store.ManageCommunityMember(r.Context(), parts[0], principal.AccountID, req.AccountID, req.Role); err != nil {
			handleStorageError(w, err)
			return
		}
		a.recordAuditEvent(r.Context(), &principal.AccountID, "community.member.updated", map[string]string{"community_id": parts[0], "target_account_id": req.AccountID, "role": req.Role})
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	if len(parts) == 2 && parts[1] == "channels" && r.Method == http.MethodGet {
		channels, err := a.Store.ListChannels(r.Context(), parts[0], principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"channels": channels})
		return
	}
	if len(parts) == 2 && parts[1] == "channels" && r.Method == http.MethodPost {
		var req struct {
			Name string `json:"name"`
			Kind string `json:"kind"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if !validDisplayName(req.Name) {
			writeError(w, http.StatusBadRequest, "invalid_name")
			return
		}
		if req.Kind == "" {
			req.Kind = "private"
		}
		if req.Kind != "private" && req.Kind != "announcement" {
			writeError(w, http.StatusBadRequest, "invalid_channel_kind")
			return
		}
		channel, conversation, err := a.Store.CreateChannelWithConversation(r.Context(), parts[0], req.Name, req.Kind, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		writeJSON(w, http.StatusCreated, map[string]interface{}{"channel": channel, "conversation": conversation})
		return
	}
	writeError(w, http.StatusNotFound, "not_found")
}

type createConversationRequest struct {
	Kind             string   `json:"kind"`
	Title            *string  `json:"title,omitempty"`
	CommunityID      *string  `json:"community_id,omitempty"`
	ChannelID        *string  `json:"channel_id,omitempty"`
	RetentionSeconds *int64   `json:"retention_seconds,omitempty"`
	MemberAccountIDs []string `json:"member_account_ids,omitempty"`
}

func (a *API) createConversation(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req createConversationRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Kind != "dm" && req.Kind != "group" && req.Kind != "community_channel" {
		writeError(w, http.StatusBadRequest, "invalid_conversation_kind")
		return
	}
	if !validRetention(req.RetentionSeconds) {
		writeError(w, http.StatusBadRequest, "invalid_retention_seconds")
		return
	}
	conversation, err := a.Store.CreateConversation(r.Context(), storage.CreateConversationInput{
		Kind:             req.Kind,
		Title:            req.Title,
		CommunityID:      req.CommunityID,
		ChannelID:        req.ChannelID,
		CreatedBy:        principal.AccountID,
		RetentionSeconds: req.RetentionSeconds,
		MemberAccountIDs: req.MemberAccountIDs,
	})
	if err != nil {
		// Surfaces ErrForbidden (community/channel mismatch or non-member) as
		// 403 and ErrNotFound (unknown channel) as 404 instead of a blanket 500.
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, conversation)
}

func (a *API) listConversations(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	conversations, err := a.Store.ListConversationsPage(r.Context(), principal.AccountID, limit, strings.TrimSpace(r.URL.Query().Get("before")))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "conversations_list_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"conversations": conversations})
}

func (a *API) conversationSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/v1/conversations/"), "/")
	if len(parts) != 2 {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	conversationID := parts[0]
	switch {
	case parts[1] == "members" && r.Method == http.MethodPost:
		var req struct {
			AccountID string `json:"account_id"`
			Role      string `json:"role"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if req.AccountID == "" {
			writeError(w, http.StatusBadRequest, "account_id_required")
			return
		}
		if req.Role == "" {
			req.Role = domain.RoleMember
		}
		if !domain.ValidRole(req.Role) {
			writeError(w, http.StatusBadRequest, "invalid_role")
			return
		}
		eventID, err := a.Store.ManageConversationMember(r.Context(), conversationID, principal.AccountID, req.AccountID, req.Role)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		a.Hub.Publish([]string{req.AccountID}, realtime.Event{Version: "v1", Type: "membership.updated", ID: eventID, ConversationID: conversationID, Payload: map[string]string{"conversation_id": conversationID, "role": req.Role}, CreatedAt: time.Now().UTC()})
		a.recordAuditEvent(r.Context(), &principal.AccountID, "conversation.member.added", map[string]string{"conversation_id": conversationID, "target_account_id": req.AccountID, "role": req.Role})
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	case parts[1] == "messages" && r.Method == http.MethodGet:
		limit := normalizeLimit(messageQueryLimit(r), 100, 200)
		before := strings.TrimSpace(r.URL.Query().Get("before"))
		after := strings.TrimSpace(r.URL.Query().Get("after"))
		if before != "" && after != "" {
			writeError(w, http.StatusBadRequest, "before_and_after_exclusive")
			return
		}
		messages, err := a.Store.ListMessages(r.Context(), conversationID, principal.AccountID, storage.ListMessagesOptions{
			Limit:    limit,
			BeforeID: before,
			AfterID:  after,
		})
		if err != nil {
			handleStorageError(w, err)
			return
		}
		response := map[string]interface{}{"messages": messages, "limit": limit}
		// Hint that more older messages may exist; clients can re-query with
		// before=<next_before> to page backward.
		if len(messages) == limit && len(messages) > 0 {
			oldest := messages[len(messages)-1]
			response["next_before"] = oldest.ID
		}
		writeJSON(w, http.StatusOK, response)
	case parts[1] == "typing" && r.Method == http.MethodPost:
		isMember, err := a.Store.IsConversationMember(r.Context(), conversationID, principal.AccountID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "typing_publish_failed")
			return
		}
		if !isMember {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}
		if !a.allowTyping(principal.AccountID, conversationID, time.Now()) {
			writeError(w, http.StatusTooManyRequests, "typing_rate_limited")
			return
		}
		members, err := a.Store.ListConversationMemberIDs(r.Context(), conversationID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "typing_publish_failed")
			return
		}
		a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "typing.updated", ConversationID: conversationID, Payload: map[string]string{"account_id": principal.AccountID}, CreatedAt: time.Now().UTC()})
		w.WriteHeader(http.StatusNoContent)
	case parts[1] == "read-receipts" && r.Method == http.MethodPost:
		var req struct {
			MessageID string `json:"message_id"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if req.MessageID == "" {
			writeError(w, http.StatusBadRequest, "message_id_required")
			return
		}
		if err := a.Store.MarkRead(r.Context(), conversationID, principal.AccountID, req.MessageID); err != nil {
			handleStorageError(w, err)
			return
		}
		payload := map[string]string{"account_id": principal.AccountID, "message_id": req.MessageID}
		eventID := a.saveSyncEvent(r.Context(), "read_receipt.updated", nil, conversationID, payload)
		members := a.conversationMemberIDs(r.Context(), conversationID)
		a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "read_receipt.updated", ID: eventID, ConversationID: conversationID, Payload: payload, CreatedAt: time.Now().UTC()})
		w.WriteHeader(http.StatusNoContent)
	case parts[1] == "retention" && (r.Method == http.MethodPut || r.Method == http.MethodPatch):
		var req struct {
			RetentionSeconds *int64 `json:"retention_seconds"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if !validRetention(req.RetentionSeconds) {
			writeError(w, http.StatusBadRequest, "invalid_retention_seconds")
			return
		}
		conversation, err := a.Store.UpdateConversationRetention(r.Context(), conversationID, principal.AccountID, req.RetentionSeconds)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		retentionMeta := map[string]interface{}{"conversation_id": conversationID}
		if req.RetentionSeconds != nil {
			retentionMeta["retention_seconds"] = *req.RetentionSeconds
		}
		a.recordAuditEvent(r.Context(), &principal.AccountID, "conversation.retention.updated", retentionMeta)
		eventID := a.saveSyncEvent(r.Context(), "retention.updated", nil, conversationID, conversation)
		members := a.conversationMemberIDs(r.Context(), conversationID)
		a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "retention.updated", ID: eventID, ConversationID: conversationID, Payload: conversation, CreatedAt: time.Now().UTC()})
		writeJSON(w, http.StatusOK, conversation)
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

func (a *API) allowTyping(accountID, conversationID string, now time.Time) bool {
	a.typingMu.Lock()
	defer a.typingMu.Unlock()
	if a.typingLast == nil {
		a.typingLast = make(map[string]time.Time)
	}
	key := accountID + "\x00" + conversationID
	if last := a.typingLast[key]; !last.IsZero() && now.Sub(last) < 2*time.Second {
		return false
	}
	a.typingLast[key] = now
	if len(a.typingLast) > 10_000 {
		cutoff := now.Add(-time.Minute)
		for item, last := range a.typingLast {
			if last.Before(cutoff) {
				delete(a.typingLast, item)
			}
		}
	}
	return true
}

type messageEnvelopeRequest struct {
	ConversationID string          `json:"conversation_id"`
	IdempotencyKey string          `json:"idempotency_key"`
	Ciphertext     []byte          `json:"ciphertext"`
	CryptoProtocol string          `json:"crypto_protocol"`
	CryptoMetadata json.RawMessage `json:"crypto_metadata,omitempty"`
	AttachmentRefs json.RawMessage `json:"attachment_refs,omitempty"`
	ReplyToID      *string         `json:"reply_to_id,omitempty"`
	ThreadRootID   *string         `json:"thread_root_id,omitempty"`
	ExpiresAt      *time.Time      `json:"expires_at,omitempty"`
}

func (a *API) createMessageEnvelope(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	raw, ok := readLimitedJSON(w, r)
	if !ok {
		return
	}
	if containsPlaintextMessageKey(raw) {
		writeError(w, http.StatusBadRequest, "plaintext_message_fields_forbidden")
		return
	}
	var req messageEnvelopeRequest
	if !decodeRawJSON(w, raw, &req) {
		return
	}
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	if req.ConversationID == "" || req.IdempotencyKey == "" || len(req.Ciphertext) == 0 || req.CryptoProtocol == "" {
		writeError(w, http.StatusBadRequest, "invalid_encrypted_envelope")
		return
	}
	if len(req.IdempotencyKey) > 128 || len(req.CryptoProtocol) > 64 {
		writeError(w, http.StatusBadRequest, "invalid_encrypted_envelope")
		return
	}
	if req.ExpiresAt != nil && !req.ExpiresAt.After(time.Now().UTC()) {
		writeError(w, http.StatusBadRequest, "invalid_expires_at")
		return
	}
	result, err := a.messageService().Create(r.Context(), domain.MessageEnvelope{
		ConversationID:  req.ConversationID,
		SenderAccountID: principal.AccountID,
		SenderDeviceID:  principal.DeviceID,
		IdempotencyKey:  req.IdempotencyKey,
		Ciphertext:      req.Ciphertext,
		CryptoProtocol:  req.CryptoProtocol,
		CryptoMetadata:  req.CryptoMetadata,
		AttachmentRefs:  req.AttachmentRefs,
		ReplyToID:       req.ReplyToID,
		ThreadRootID:    req.ThreadRootID,
		ExpiresAt:       req.ExpiresAt,
	})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if !result.Duplicate {
		a.Hub.Publish(result.Recipients, realtime.Event{Version: "v1", Type: "message.envelope.created", ID: result.EventID, ConversationID: result.Envelope.ConversationID, Payload: result.Envelope, CreatedAt: time.Now().UTC()})
		a.notifyPush(r.Context(), result.Envelope.ConversationID, principal.AccountID)
	}
	status := http.StatusCreated
	if result.Duplicate {
		status = http.StatusOK
	}
	writeJSON(w, status, result.Envelope)
}

func (a *API) messageService() *messaging.Service {
	if a.Messages != nil {
		return a.Messages
	}
	return messaging.New(a.Store)
}

type encryptedMessageMutationRequest struct {
	Ciphertext     []byte          `json:"ciphertext"`
	CryptoProtocol string          `json:"crypto_protocol"`
	CryptoMetadata json.RawMessage `json:"crypto_metadata,omitempty"`
}

func (a *API) messageSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/v1/messages/"), "/")
	if len(parts) != 2 {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	messageID := parts[0]
	switch {
	case parts[1] == "edit" && r.Method == http.MethodPost:
		req, ok := decodeEncryptedMutation(w, r)
		if !ok {
			return
		}
		envelope, err := a.Store.UpdateMessageEnvelope(r.Context(), messageID, principal.AccountID, req.Ciphertext, req.CryptoProtocol, req.CryptoMetadata)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		a.publishMessageEvent(r, "message.envelope.edited", envelope)
		writeJSON(w, http.StatusOK, envelope)
	case parts[1] == "delete" && r.Method == http.MethodPost:
		req, ok := decodeEncryptedMutation(w, r)
		if !ok {
			return
		}
		envelope, err := a.Store.DeleteMessageEnvelope(r.Context(), messageID, principal.AccountID, req.Ciphertext, req.CryptoProtocol, req.CryptoMetadata)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		a.publishMessageEvent(r, "message.envelope.deleted", envelope)
		writeJSON(w, http.StatusOK, envelope)
	case parts[1] == "reactions" && r.Method == http.MethodGet:
		reactions, err := a.Store.ListReactions(r.Context(), messageID, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"reactions": reactions})
	case parts[1] == "reactions" && r.Method == http.MethodDelete:
		conversationID, err := a.Store.DeleteReaction(r.Context(), messageID, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		payload := map[string]string{"message_id": messageID, "account_id": principal.AccountID}
		eventID := a.saveSyncEvent(r.Context(), "reaction.deleted", nil, conversationID, payload)
		members := a.conversationMemberIDs(r.Context(), conversationID)
		a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "reaction.deleted", ID: eventID, ConversationID: conversationID, Payload: payload, CreatedAt: time.Now().UTC()})
		w.WriteHeader(http.StatusNoContent)
	case parts[1] == "reactions" && r.Method == http.MethodPost:
		raw, ok := readLimitedJSON(w, r)
		if !ok {
			return
		}
		if containsPlaintextMessageKey(raw) {
			writeError(w, http.StatusBadRequest, "plaintext_message_fields_forbidden")
			return
		}
		var req struct {
			ReactionCiphertext []byte `json:"reaction_ciphertext"`
		}
		if !decodeRawJSON(w, raw, &req) {
			return
		}
		if len(req.ReactionCiphertext) == 0 {
			writeError(w, http.StatusBadRequest, "reaction_ciphertext_required")
			return
		}
		if err := a.Store.CreateReaction(r.Context(), messageID, principal.AccountID, req.ReactionCiphertext); err != nil {
			handleStorageError(w, err)
			return
		}
		message, err := a.Store.MessageByID(r.Context(), messageID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		payload := map[string]string{"message_id": messageID, "account_id": principal.AccountID}
		eventID := a.saveSyncEvent(r.Context(), "reaction.created", nil, message.ConversationID, payload)
		members := a.conversationMemberIDs(r.Context(), message.ConversationID)
		a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "reaction.created", ID: eventID, ConversationID: message.ConversationID, Payload: payload, CreatedAt: time.Now().UTC()})
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

func decodeEncryptedMutation(w http.ResponseWriter, r *http.Request) (encryptedMessageMutationRequest, bool) {
	raw, ok := readLimitedJSON(w, r)
	if !ok {
		return encryptedMessageMutationRequest{}, false
	}
	if containsPlaintextMessageKey(raw) {
		writeError(w, http.StatusBadRequest, "plaintext_message_fields_forbidden")
		return encryptedMessageMutationRequest{}, false
	}
	var req encryptedMessageMutationRequest
	if !decodeRawJSON(w, raw, &req) {
		return encryptedMessageMutationRequest{}, false
	}
	if len(req.Ciphertext) == 0 || req.CryptoProtocol == "" {
		writeError(w, http.StatusBadRequest, "invalid_encrypted_marker")
		return encryptedMessageMutationRequest{}, false
	}
	return req, true
}

func (a *API) publishMessageEvent(r *http.Request, eventType string, envelope domain.MessageEnvelope) {
	ref := messageEventRef(envelope)
	eventID := a.saveSyncEvent(r.Context(), eventType, nil, envelope.ConversationID, ref)
	members := a.conversationMemberIDs(r.Context(), envelope.ConversationID)
	a.Hub.Publish(members, realtime.Event{Version: "v1", Type: eventType, ID: eventID, ConversationID: envelope.ConversationID, Payload: envelope, CreatedAt: time.Now().UTC()})
}

func (a *API) saveSyncEvent(ctx context.Context, eventType string, accountID *string, conversationID string, payload interface{}) int64 {
	eventID, err := a.Store.SaveSyncEvent(ctx, eventType, accountID, conversationID, payload)
	if err != nil {
		a.warn("sync_event_save_failed", "event_type", eventType, "err", err)
	}
	return eventID
}

func (a *API) conversationMemberIDs(ctx context.Context, conversationID string) []string {
	members, err := a.Store.ListConversationMemberIDs(ctx, conversationID)
	if err != nil {
		a.warn("conversation_member_list_failed", "conversation_id", conversationID, "err", err)
		return nil
	}
	return members
}

func (a *API) recordAuditEvent(ctx context.Context, actorAccountID *string, eventType string, metadata interface{}) {
	if err := a.Store.RecordAuditEvent(ctx, actorAccountID, eventType, metadata); err != nil {
		a.warn("audit_event_record_failed", "event_type", eventType, "err", err)
	}
}

func (a *API) warn(message string, args ...interface{}) {
	if a.Log != nil {
		a.Log.Warn(message, args...)
	}
}

// messageEventRef is the compact form persisted in sync_events.payload_json:
// just the IDs the client needs to refetch the full envelope, never the
// ciphertext. This keeps the audit/sync log from duplicating message bodies.
func messageEventRef(envelope domain.MessageEnvelope) map[string]interface{} {
	ref := map[string]interface{}{
		"message_id":      envelope.ID,
		"conversation_id": envelope.ConversationID,
	}
	if envelope.EditedAt != nil {
		ref["edited_at"] = envelope.EditedAt
	}
	if envelope.DeletedAt != nil {
		ref["deleted_at"] = envelope.DeletedAt
	}
	return ref
}
