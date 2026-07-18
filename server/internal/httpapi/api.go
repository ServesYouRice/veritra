package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/mail"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/messaging"
	"private-messenger/server/internal/push"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
)

type API struct {
	Store               *storage.Store
	Hub                 *realtime.Hub
	Blobs               uploads.Store
	Log                 *slog.Logger
	SetupToken          string
	DefaultInstanceName string
	Messages            *messaging.Service
	Push                push.Provider
	VAPIDPublicKey      string
	typingMu            sync.Mutex
	typingLast          map[string]time.Time
}

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /livez", a.liveness)
	mux.HandleFunc("GET /healthz", a.health)
	mux.HandleFunc("GET /readyz", a.health)
	mux.HandleFunc("GET /api/v1/health", a.health)
	mux.HandleFunc("GET /setup", a.setupPage)
	mux.HandleFunc("GET /api/v1/setup/status", a.setupStatus)
	mux.HandleFunc("POST /api/v1/setup/owner/enrollment", a.reserveOwnerEnrollment)
	mux.HandleFunc("POST /api/v1/setup/owner", a.createOwner)
	mux.HandleFunc("POST /api/v1/auth/login", a.login)
	mux.HandleFunc("POST /api/v1/auth/reauth", a.withAuth(a.reauthenticate))
	mux.HandleFunc("POST /api/v1/auth/logout", a.withAuth(a.logout))
	mux.HandleFunc("POST /api/v1/auth/logout-all", a.withRecentAuth(a.logoutAll))
	mux.HandleFunc("POST /api/v1/account/password", a.withRecentAuth(a.changePassword))
	mux.HandleFunc("POST /api/v1/register", a.register)
	mux.HandleFunc("POST /api/v1/register/enrollment", a.reserveRegistrationEnrollment)
	mux.HandleFunc("POST /api/v1/invites", a.withRecentAuth(a.createInvite))
	mux.HandleFunc("GET /api/v1/invites", a.withAuth(a.listInvites))
	mux.HandleFunc("DELETE /api/v1/invites/{id}", a.withRecentAuth(a.revokeInvite))
	mux.HandleFunc("GET /api/v1/devices/me", a.withAuth(a.listDevices))
	mux.HandleFunc("POST /api/v1/devices/me/key-packages", a.withAuth(a.publishDeviceKeyPackages))
	mux.HandleFunc("DELETE /api/v1/devices/{id}", a.withRecentAuth(a.revokeDevice))
	mux.HandleFunc("POST /api/v1/device-links", a.withRecentAuth(a.createDeviceLink))
	mux.HandleFunc("POST /api/v1/device-links/claim-enrollment", a.reserveDeviceLinkEnrollment)
	mux.HandleFunc("POST /api/v1/device-links/claim", a.claimDeviceLink)
	mux.HandleFunc("POST /api/v1/communities", a.withAuth(a.createCommunity))
	mux.HandleFunc("GET /api/v1/communities", a.withAuth(a.listCommunities))
	mux.HandleFunc("POST /api/v1/conversations", a.withAuth(a.createConversation))
	mux.HandleFunc("GET /api/v1/conversations", a.withAuth(a.listConversations))
	mux.HandleFunc("POST /api/v1/conversations/{id}/key-packages/claim", a.withAuth(a.claimConversationKeyPackages))
	mux.HandleFunc("POST /api/v1/messages/envelopes", a.withAuth(a.createMessageEnvelope))
	mux.HandleFunc("POST /api/v1/attachments", a.withAuth(a.uploadAttachment))
	mux.HandleFunc("GET /api/v1/attachments", a.withAuth(a.listAttachments))
	mux.HandleFunc("POST /api/v1/push/subscriptions", a.withAuth(a.createPushSubscription))
	mux.HandleFunc("GET /api/v1/push/config", a.withAuth(a.pushConfig))
	mux.HandleFunc("DELETE /api/v1/push/subscriptions/{id}", a.withAuth(a.deletePushSubscription))
	mux.HandleFunc("POST /api/v1/calls", a.withAuth(a.createCall))
	mux.HandleFunc("GET /api/v1/calls", a.withAuth(a.listCalls))
	mux.HandleFunc("/api/v1/calls/", a.withAuth(a.callSubroute))
	mux.HandleFunc("GET /api/v1/sync/ws", a.syncWebSocket)
	mux.HandleFunc("GET /api/v1/sync/events", a.withAuth(a.syncEvents))
	mux.HandleFunc("GET /api/v1/search/metadata", a.withAuth(a.searchMetadata))
	mux.HandleFunc("GET /api/v1/account/export", a.withAuth(a.exportAccount))
	mux.HandleFunc("DELETE /api/v1/account", a.withRecentAuth(a.deleteAccount))
	mux.HandleFunc("GET /api/v1/account/blocks", a.withAuth(a.listAccountBlocks))
	mux.HandleFunc("PUT /api/v1/account/blocks/{id}", a.withAuth(a.blockAccount))
	mux.HandleFunc("DELETE /api/v1/account/blocks/{id}", a.withAuth(a.unblockAccount))
	mux.HandleFunc("GET /api/v1/admin/accounts", a.withAuth(a.listAdminAccounts))
	mux.HandleFunc("PATCH /api/v1/admin/accounts/{id}/status", a.withRecentAuth(a.setAdminAccountStatus))
	mux.HandleFunc("GET /api/v1/admin/audit-events", a.withAuth(a.listAdminAuditEvents))
	mux.HandleFunc("DELETE /api/v1/admin/invites/{id}", a.withRecentAuth(a.adminRevokeInvite))
	mux.HandleFunc("POST /api/v1/backups", a.withAuth(a.uploadBackup))
	mux.HandleFunc("GET /api/v1/backups", a.withAuth(a.listBackups))
	mux.HandleFunc("/api/v1/attachments/", a.withAuth(a.attachmentSubroute))
	mux.HandleFunc("/api/v1/backups/", a.withAuth(a.backupSubroute))
	mux.HandleFunc("/api/v1/messages/", a.withAuth(a.messageSubroute))
	mux.HandleFunc("/api/v1/conversations/", a.withAuth(a.conversationSubroute))
	mux.HandleFunc("/api/v1/communities/", a.withAuth(a.communitySubroute))
	mux.HandleFunc("/api/v1/device-links/", a.deviceLinkSubroute)
}

func bearerToken(r *http.Request) string {
	authz := r.Header.Get("Authorization")
	const scheme = "Bearer "
	if len(authz) < len(scheme) || !strings.EqualFold(authz[:len(scheme)], scheme) {
		return ""
	}
	return strings.TrimSpace(authz[len(scheme):])
}

// logout revokes the caller's current session token.
func (a *API) withAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		principal, err := a.principalFromRequest(r)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		if err := a.Store.MarkDeviceSeen(r.Context(), principal.DeviceID); err != nil {
			a.warn("device_last_seen_update_failed", "err", err)
		}
		next(w, r, principal)
	}
}

func (a *API) withRecentAuth(next authedHandler) http.HandlerFunc {
	return a.withAuth(func(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
		if !recentlyAuthenticated(principal) {
			writeError(w, http.StatusForbidden, "recent_auth_required")
			return
		}
		next(w, r, principal)
	})
}

func recentlyAuthenticated(principal domain.Principal) bool {
	return principal.DeviceID != "" && principal.RecentAuthAt != nil && principal.RecentAuthAt.After(time.Now().UTC().Add(-5*time.Minute))
}

func (a *API) principalFromRequest(r *http.Request) (domain.Principal, error) {
	authz := r.Header.Get("Authorization")
	const scheme = "Bearer "
	if len(authz) < len(scheme) || !strings.EqualFold(authz[:len(scheme)], scheme) {
		return domain.Principal{}, storage.ErrUnauthorized
	}
	token := strings.TrimSpace(authz[len(scheme):])
	if token == "" {
		return domain.Principal{}, storage.ErrUnauthorized
	}
	return a.Store.PrincipalByTokenHash(r.Context(), auth.HashToken(token))
}

func (a *API) effectiveConversationRole(ctx context.Context, conversationID string, principal domain.Principal) (string, error) {
	convRole, err := a.Store.ConversationMemberRole(ctx, conversationID, principal.AccountID)
	if err != nil {
		return "", err
	}
	return convRole, nil
}

func readLimitedJSON(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	defer r.Body.Close()
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return nil, false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		writeError(w, http.StatusBadRequest, "empty_body")
		return nil, false
	}
	return raw, true
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dest interface{}) bool {
	raw, ok := readLimitedJSON(w, r)
	if !ok {
		return false
	}
	return decodeRawJSON(w, raw, dest)
}

func decodeOptionalJSON(w http.ResponseWriter, r *http.Request, dest interface{}) bool {
	defer r.Body.Close()
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return true
	}
	return decodeRawJSON(w, raw, dest)
}

func decodeRawJSON(w http.ResponseWriter, raw []byte, dest interface{}) bool {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dest); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return false
	}
	// Reject trailing data after the first JSON value so a request body cannot
	// smuggle a second document past the decoder.
	var extra struct{}
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return false
	}
	return true
}

func containsPlaintextMessageKey(raw []byte) bool {
	var value interface{}
	if err := json.Unmarshal(raw, &value); err != nil {
		return false
	}
	return containsForbiddenPlaintextKey(value)
}

func containsForbiddenPlaintextKey(value interface{}) bool {
	switch typed := value.(type) {
	case map[string]interface{}:
		for key, nested := range typed {
			if isForbiddenPlaintextKey(key) || containsForbiddenPlaintextKey(nested) {
				return true
			}
		}
	case []interface{}:
		for _, nested := range typed {
			if containsForbiddenPlaintextKey(nested) {
				return true
			}
		}
	}
	return false
}

func isForbiddenPlaintextKey(key string) bool {
	switch strings.ToLower(key) {
	case "plaintext", "plain_text", "body", "text", "message", "message_text", "content":
		return true
	default:
		return false
	}
}

func optionalQuery(r *http.Request, name string) *string {
	value := strings.TrimSpace(r.URL.Query().Get(name))
	if value == "" {
		return nil
	}
	return &value
}

func normalizeLimit(value, fallback, max int) int {
	if value <= 0 || value > max {
		return fallback
	}
	return value
}

func normalizeOffset(value int) int {
	if value < 0 {
		return 0
	}
	return value
}

// validRetention bounds the retention window to [0, 10 years]. A nil pointer
// (no retention) is allowed.
func validRetention(seconds *int64) bool {
	if seconds == nil {
		return true
	}
	const tenYears int64 = 10 * 365 * 24 * 60 * 60
	return *seconds >= 0 && *seconds <= tenYears
}

func isReservedNonProductionKeyPackage(keyPackage []byte) bool {
	marker := strings.ToLower(string(keyPackage))
	return strings.Contains(marker, "test_only") ||
		strings.Contains(marker, "test-only") ||
		strings.Contains(marker, "non-production") ||
		strings.Contains(marker, "placeholder")
}

func validDisplayName(name string) bool {
	trimmed := strings.TrimSpace(name)
	return trimmed != "" && len(trimmed) <= 64
}

// validUsername enforces an ASCII-only charset (letters, digits, '_', '-') and a
// 3-32 character length bound. ASCII-only is deliberate: it keeps usernames free
// of confusable/homoglyph characters (e.g. Cyrillic 'а' vs Latin 'a') that could
// be used to impersonate another account, and it keeps NormalizeUsername's
// case-folding unambiguous (no Unicode fold collisions).
func validUsername(username string) bool {
	username = strings.TrimSpace(username)
	if len(username) < 3 || len(username) > 32 {
		return false
	}
	for i := 0; i < len(username); i++ {
		c := username[i]
		isLower := c >= 'a' && c <= 'z'
		isUpper := c >= 'A' && c <= 'Z'
		isDigit := c >= '0' && c <= '9'
		if !isLower && !isUpper && !isDigit && c != '_' && c != '-' {
			return false
		}
	}
	return true
}

func validOptionalEmail(email *string) bool {
	if email == nil {
		return true
	}
	value := strings.TrimSpace(*email)
	if value == "" || len(value) > 254 {
		return false
	}
	parsed, err := mail.ParseAddress(value)
	return err == nil && parsed.Address == value
}

func messageQueryLimit(r *http.Request) int {
	v, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	return v
}

func deviceLinkPayload(link domain.DeviceLink) map[string]interface{} {
	payload := map[string]interface{}{
		"id":                link.ID,
		"state":             link.State,
		"verification_code": link.VerificationCode,
		"created_at":        link.CreatedAt,
		"expires_at":        link.ExpiresAt,
	}
	if link.Code != "" {
		payload["code"] = link.Code
		payload["link_uri"] = "veritra://device-link?code=" + url.QueryEscape(link.Code)
	}
	if link.ClaimedDeviceName != nil {
		payload["claimed_device_name"] = *link.ClaimedDeviceName
	}
	if link.ApprovedDeviceID != nil {
		payload["approved_device_id"] = *link.ApprovedDeviceID
	}
	return payload
}

func handleStorageError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, storage.ErrUnauthorized):
		writeError(w, http.StatusUnauthorized, "unauthorized")
	case errors.Is(err, storage.ErrNotMember), errors.Is(err, storage.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden")
	case errors.Is(err, storage.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case errors.Is(err, storage.ErrInvalidInput):
		writeError(w, http.StatusBadRequest, "invalid_input")
	case errors.Is(err, storage.ErrLastOwner):
		writeError(w, http.StatusConflict, "last_owner_required")
	case errors.Is(err, storage.ErrIdempotencyConflict):
		writeError(w, http.StatusConflict, "idempotency_conflict")
	case errors.Is(err, storage.ErrDeviceLinkInvalid):
		writeError(w, http.StatusBadRequest, "invalid_device_link")
	case errors.Is(err, storage.ErrStorageQuota):
		writeError(w, http.StatusInsufficientStorage, "storage_quota_exceeded")
	default:
		writeError(w, http.StatusInternalServerError, "storage_error")
	}
}

func writeJSON(w http.ResponseWriter, status int, value interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}
