package httpapi

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/mail"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/messaging"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
	"private-messenger/server/websetup"
)

type API struct {
	Store               *storage.Store
	Hub                 *realtime.Hub
	Blobs               uploads.Store
	Log                 *slog.Logger
	SetupToken          string
	DefaultInstanceName string
	Messages            *messaging.Service
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
	mux.HandleFunc("POST /api/v1/setup/owner", a.createOwner)
	mux.HandleFunc("POST /api/v1/auth/login", a.login)
	mux.HandleFunc("POST /api/v1/auth/reauth", a.withAuth(a.reauthenticate))
	mux.HandleFunc("POST /api/v1/auth/logout", a.withAuth(a.logout))
	mux.HandleFunc("POST /api/v1/auth/logout-all", a.withRecentAuth(a.logoutAll))
	mux.HandleFunc("POST /api/v1/account/password", a.withRecentAuth(a.changePassword))
	mux.HandleFunc("POST /api/v1/register", a.register)
	mux.HandleFunc("POST /api/v1/invites", a.withRecentAuth(a.createInvite))
	mux.HandleFunc("GET /api/v1/invites", a.withAuth(a.listInvites))
	mux.HandleFunc("DELETE /api/v1/invites/{id}", a.withRecentAuth(a.revokeInvite))
	mux.HandleFunc("GET /api/v1/devices/me", a.withAuth(a.listDevices))
	mux.HandleFunc("DELETE /api/v1/devices/{id}", a.withRecentAuth(a.revokeDevice))
	mux.HandleFunc("POST /api/v1/device-links", a.withRecentAuth(a.createDeviceLink))
	mux.HandleFunc("POST /api/v1/device-links/claim", a.claimDeviceLink)
	mux.HandleFunc("POST /api/v1/communities", a.withAuth(a.createCommunity))
	mux.HandleFunc("GET /api/v1/communities", a.withAuth(a.listCommunities))
	mux.HandleFunc("POST /api/v1/conversations", a.withAuth(a.createConversation))
	mux.HandleFunc("GET /api/v1/conversations", a.withAuth(a.listConversations))
	mux.HandleFunc("POST /api/v1/messages/envelopes", a.withAuth(a.createMessageEnvelope))
	mux.HandleFunc("POST /api/v1/attachments", a.withAuth(a.uploadAttachment))
	mux.HandleFunc("GET /api/v1/attachments", a.withAuth(a.listAttachments))
	mux.HandleFunc("POST /api/v1/push/subscriptions", a.withAuth(a.createPushSubscription))
	mux.HandleFunc("DELETE /api/v1/push/subscriptions/{id}", a.withAuth(a.deletePushSubscription))
	mux.HandleFunc("POST /api/v1/calls", a.withAuth(a.createCall))
	mux.HandleFunc("GET /api/v1/calls", a.withAuth(a.listCalls))
	mux.HandleFunc("/api/v1/calls/", a.withAuth(a.callSubroute))
	mux.HandleFunc("GET /api/v1/sync/ws", a.syncWebSocket)
	mux.HandleFunc("GET /api/v1/sync/events", a.withAuth(a.syncEvents))
	mux.HandleFunc("GET /api/v1/search/metadata", a.withAuth(a.searchMetadata))
	mux.HandleFunc("GET /api/v1/account/export", a.withAuth(a.exportAccount))
	mux.HandleFunc("DELETE /api/v1/account", a.withRecentAuth(a.deleteAccount))
	mux.HandleFunc("POST /api/v1/backups", a.withAuth(a.uploadBackup))
	mux.HandleFunc("GET /api/v1/backups", a.withAuth(a.listBackups))
	mux.HandleFunc("/api/v1/attachments/", a.withAuth(a.attachmentSubroute))
	mux.HandleFunc("/api/v1/backups/", a.withAuth(a.backupSubroute))
	mux.HandleFunc("/api/v1/messages/", a.withAuth(a.messageSubroute))
	mux.HandleFunc("/api/v1/conversations/", a.withAuth(a.conversationSubroute))
	mux.HandleFunc("/api/v1/communities/", a.withAuth(a.communitySubroute))
	mux.HandleFunc("/api/v1/device-links/", a.deviceLinkSubroute)
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	if err := a.Store.CheckReady(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "storage_unavailable")
		return
	}
	if err := a.Blobs.Check(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "blob_storage_unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *API) liveness(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "alive"})
}

func (a *API) setupPage(w http.ResponseWriter, r *http.Request) {
	page, err := websetup.FS.ReadFile("index.html")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "setup_ui_unavailable")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(page)
}

func (a *API) setupStatus(w http.ResponseWriter, r *http.Request) {
	required, err := a.Store.SetupRequired(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "setup_status_failed")
		return
	}
	response := map[string]interface{}{"setup_required": required}
	if !required {
		name, err := a.Store.InstanceName(r.Context())
		if err != nil {
			writeError(w, http.StatusInternalServerError, "setup_status_failed")
			return
		}
		response["instance_name"] = name
	} else if strings.TrimSpace(a.DefaultInstanceName) != "" {
		response["instance_name"] = strings.TrimSpace(a.DefaultInstanceName)
	}
	writeJSON(w, http.StatusOK, response)
}

type ownerRequest struct {
	InstanceName     string  `json:"instance_name"`
	Username         string  `json:"username"`
	Email            *string `json:"email,omitempty"`
	Password         string  `json:"password"`
	DeviceName       string  `json:"device_name"`
	DeviceKeyPackage []byte  `json:"device_key_package"`
}

func (a *API) createOwner(w http.ResponseWriter, r *http.Request) {
	if !a.setupAuthorized(r) {
		writeError(w, http.StatusForbidden, "setup_authorization_required")
		return
	}
	var req ownerRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.InstanceName) == "" {
		req.InstanceName = a.DefaultInstanceName
	}
	if !validDisplayName(req.InstanceName) || !validUsername(req.Username) || !validOptionalEmail(req.Email) {
		writeError(w, http.StatusBadRequest, "invalid_identity")
		return
	}
	passwordHash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusBadRequest, "weak_password")
		return
	}
	if len(req.DeviceKeyPackage) == 0 {
		writeError(w, http.StatusBadRequest, "device_key_package_required")
		return
	}
	if !validDisplayName(req.DeviceName) {
		writeError(w, http.StatusBadRequest, "invalid_device_name")
		return
	}
	if isReservedNonProductionKeyPackage(req.DeviceKeyPackage) {
		writeError(w, http.StatusBadRequest, "non_production_device_key_package")
		return
	}
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token_create_failed")
		return
	}
	deviceSecret, deviceAuthHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "device_secret_create_failed")
		return
	}
	created, err := a.Store.CreateOwner(r.Context(), storage.CreateOwnerInput{
		InstanceName:   req.InstanceName,
		Username:       req.Username,
		Email:          req.Email,
		PasswordHash:   passwordHash,
		DeviceName:     req.DeviceName,
		KeyPackage:     req.DeviceKeyPackage,
		DeviceAuthHash: deviceAuthHash,
		SessionHash:    tokenHash,
		SessionExpiry:  time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		if errors.Is(err, storage.ErrAlreadySetup) {
			writeError(w, http.StatusConflict, "already_setup")
			return
		}
		writeError(w, http.StatusInternalServerError, "owner_create_failed")
		return
	}
	a.recordAuditEvent(r.Context(), &created.Account.ID, "owner.created", map[string]string{"device_id": created.Device.ID})
	writeJSON(w, http.StatusCreated, map[string]interface{}{"account": created.Account, "device": created.Device, "token": token, "device_secret": deviceSecret})
}

func (a *API) setupAuthorized(r *http.Request) bool {
	if a.SetupToken != "" {
		provided := r.Header.Get("X-Veritra-Setup-Token")
		return len(provided) == len(a.SetupToken) &&
			subtle.ConstantTimeCompare([]byte(provided), []byte(a.SetupToken)) == 1
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

type loginRequest struct {
	Username     string `json:"username"`
	Password     string `json:"password"`
	DeviceID     string `json:"device_id,omitempty"`
	DeviceSecret string `json:"device_secret"`
}

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.DeviceID) == "" {
		writeError(w, http.StatusBadRequest, "device_id_required")
		return
	}
	record, lookupErr := a.Store.LoginRecord(r.Context(), req.Username, req.DeviceID)
	// Always run bcrypt — against a dummy hash when the lookup failed — so
	// response time does not leak whether the username exists.
	var storedHash string
	if lookupErr == nil {
		storedHash = record.PasswordHash
	}
	passwordOK := auth.VerifyPasswordOrDummy(storedHash, req.Password)
	deviceOK := lookupErr == nil && record.DeviceAuthHash != "" && subtle.ConstantTimeCompare([]byte(auth.HashToken(req.DeviceSecret)), []byte(record.DeviceAuthHash)) == 1
	if lookupErr != nil || !passwordOK || !deviceOK {
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token_create_failed")
		return
	}
	if err := a.Store.CreateSession(r.Context(), tokenHash, record.AccountID, record.DeviceID, time.Now().UTC().Add(30*24*time.Hour)); err != nil {
		writeError(w, http.StatusInternalServerError, "session_create_failed")
		return
	}
	a.recordAuditEvent(r.Context(), &record.AccountID, "session.login", map[string]string{"device_id": record.DeviceID})
	writeJSON(w, http.StatusOK, map[string]interface{}{"token": token, "account_id": record.AccountID, "device_id": record.DeviceID, "role": record.Role})
}

type registerRequest struct {
	InviteCode       string  `json:"invite_code"`
	Username         string  `json:"username"`
	Email            *string `json:"email,omitempty"`
	Password         string  `json:"password"`
	DeviceName       string  `json:"device_name"`
	DeviceKeyPackage []byte  `json:"device_key_package"`
}

func (a *API) register(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validUsername(req.Username) || !validOptionalEmail(req.Email) {
		writeError(w, http.StatusBadRequest, "invalid_identity")
		return
	}
	passwordHash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeError(w, http.StatusBadRequest, "weak_password")
		return
	}
	if len(req.DeviceKeyPackage) == 0 {
		writeError(w, http.StatusBadRequest, "device_key_package_required")
		return
	}
	if !validDisplayName(req.DeviceName) {
		writeError(w, http.StatusBadRequest, "invalid_device_name")
		return
	}
	if isReservedNonProductionKeyPackage(req.DeviceKeyPackage) {
		writeError(w, http.StatusBadRequest, "non_production_device_key_package")
		return
	}
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token_create_failed")
		return
	}
	deviceSecret, deviceAuthHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "device_secret_create_failed")
		return
	}
	created, err := a.Store.RegisterWithInvite(r.Context(), storage.RegisterInput{
		InviteCode:     req.InviteCode,
		Username:       req.Username,
		Email:          req.Email,
		PasswordHash:   passwordHash,
		DeviceName:     req.DeviceName,
		KeyPackage:     req.DeviceKeyPackage,
		DeviceAuthHash: deviceAuthHash,
		SessionHash:    tokenHash,
		SessionExpiry:  time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		if errors.Is(err, storage.ErrInviteInvalid) {
			writeError(w, http.StatusBadRequest, "invalid_invite")
			return
		}
		writeError(w, http.StatusInternalServerError, "register_failed")
		return
	}
	a.recordAuditEvent(r.Context(), &created.Account.ID, "account.registered", map[string]string{"device_id": created.Device.ID})
	writeJSON(w, http.StatusCreated, map[string]interface{}{"account": created.Account, "device": created.Device, "token": token, "device_secret": deviceSecret})
}

type inviteRequest struct {
	MaxUses   int        `json:"max_uses"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
}

func (a *API) createInvite(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !domain.CanManageInvites(principal.Role) {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	var req inviteRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ExpiresAt != nil {
		now := time.Now().UTC()
		if !req.ExpiresAt.After(now) {
			writeError(w, http.StatusBadRequest, "invalid_expires_at")
			return
		}
		if req.ExpiresAt.Sub(now) > 90*24*time.Hour {
			writeError(w, http.StatusBadRequest, "expires_at_too_far")
			return
		}
	}
	if req.ExpiresAt == nil {
		defaultExpiry := time.Now().UTC().Add(7 * 24 * time.Hour)
		req.ExpiresAt = &defaultExpiry
	}
	if req.MaxUses < 0 || req.MaxUses > 10000 {
		writeError(w, http.StatusBadRequest, "invalid_max_uses")
		return
	}
	invite, err := a.Store.CreateInvite(r.Context(), principal.AccountID, req.MaxUses, req.ExpiresAt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "invite_create_failed")
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "invite.created", map[string]interface{}{"invite_id": invite.ID, "max_uses": invite.MaxUses})
	writeJSON(w, http.StatusCreated, invite)
}

func (a *API) revokeInvite(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !domain.CanManageInvites(principal.Role) {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	inviteID := strings.TrimSpace(r.PathValue("id"))
	if inviteID == "" {
		writeError(w, http.StatusBadRequest, "invalid_invite_id")
		return
	}
	if err := a.Store.RevokeInvite(r.Context(), principal.AccountID, inviteID); err != nil {
		handleStorageError(w, err)
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "invite.revoked", map[string]string{"invite_id": inviteID})
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) listInvites(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !domain.CanManageInvites(principal.Role) {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	invites, err := a.Store.ListInvites(r.Context(), principal.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "invites_list_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"invites": invites})
}

func (a *API) listDevices(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	devices, err := a.Store.ListDevicesPage(r.Context(), principal.AccountID, limit, strings.TrimSpace(r.URL.Query().Get("after")))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "devices_list_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"devices": devices})
}

type createDeviceLinkRequest struct {
	ExpiresInSeconds int64 `json:"expires_in_seconds,omitempty"`
}

func (a *API) createDeviceLink(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	var req createDeviceLinkRequest
	if !decodeOptionalJSON(w, r, &req) {
		return
	}
	link, err := a.Store.CreateDeviceLink(r.Context(), principal.AccountID, principal.DeviceID, time.Duration(req.ExpiresInSeconds)*time.Second)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{"device_link": deviceLinkPayload(link)})
}

type claimDeviceLinkRequest struct {
	Code             string `json:"code"`
	DeviceName       string `json:"device_name"`
	DeviceKeyPackage []byte `json:"device_key_package"`
	SigningKey       []byte `json:"signing_key,omitempty"`
}

func (a *API) claimDeviceLink(w http.ResponseWriter, r *http.Request) {
	var req claimDeviceLinkRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.DeviceKeyPackage) == 0 {
		writeError(w, http.StatusBadRequest, "device_key_package_required")
		return
	}
	if !validDisplayName(req.DeviceName) {
		writeError(w, http.StatusBadRequest, "invalid_device_name")
		return
	}
	if isReservedNonProductionKeyPackage(req.DeviceKeyPackage) {
		writeError(w, http.StatusBadRequest, "non_production_device_key_package")
		return
	}
	claimToken, claimTokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "claim_token_create_failed")
		return
	}
	deviceSecret, deviceAuthHash, err := auth.NewToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "device_secret_create_failed")
		return
	}
	link, err := a.Store.ClaimDeviceLink(r.Context(), req.Code, req.DeviceName, req.DeviceKeyPackage, req.SigningKey, claimTokenHash, deviceAuthHash)
	if err != nil {
		if errors.Is(err, storage.ErrDeviceLinkInvalid) {
			writeError(w, http.StatusBadRequest, "invalid_device_link")
			return
		}
		writeError(w, http.StatusInternalServerError, "device_link_claim_failed")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]interface{}{"device_link": deviceLinkPayload(link), "claim_token": claimToken, "device_secret": deviceSecret})
}

func (a *API) deviceLinkSubroute(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/device-links/"), "/"), "/")
	if len(parts) == 1 && parts[0] != "" && r.Method == http.MethodGet {
		principal, err := a.principalFromRequest(r)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		link, err := a.Store.DeviceLinkForAccount(r.Context(), parts[0], principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"device_link": deviceLinkPayload(link)})
		return
	}
	if len(parts) != 2 {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	linkID := parts[0]
	switch {
	case parts[1] == "approve" && r.Method == http.MethodPost:
		principal, err := a.principalFromRequest(r)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		if !recentlyAuthenticated(principal) {
			writeError(w, http.StatusForbidden, "recent_auth_required")
			return
		}
		var req struct {
			VerificationCode string `json:"verification_code"`
		}
		if !decodeJSON(w, r, &req) {
			return
		}
		if strings.TrimSpace(req.VerificationCode) == "" {
			writeError(w, http.StatusBadRequest, "verification_code_required")
			return
		}
		link, device, err := a.Store.ApproveDeviceLink(r.Context(), linkID, principal.AccountID, req.VerificationCode)
		if err != nil {
			switch {
			case errors.Is(err, storage.ErrDeviceLinkVerificationFailed):
				writeError(w, http.StatusBadRequest, "verification_code_mismatch")
			case errors.Is(err, storage.ErrDeviceLinkInvalid):
				writeError(w, http.StatusBadRequest, "invalid_device_link")
			default:
				handleStorageError(w, err)
			}
			return
		}
		payload := map[string]interface{}{"device": device, "device_link_id": link.ID}
		eventID := a.saveSyncEvent(r.Context(), "device.updated", &principal.AccountID, "", payload)
		a.Hub.Publish([]string{principal.AccountID}, realtime.Event{Version: "v1", Type: "device.updated", ID: eventID, Payload: payload, CreatedAt: time.Now().UTC()})
		a.recordAuditEvent(r.Context(), &principal.AccountID, "device_link.approved", map[string]string{"link_id": link.ID, "device_id": device.ID})
		writeJSON(w, http.StatusOK, map[string]interface{}{"device_link": deviceLinkPayload(link), "device": device})
	case parts[1] == "claim-status" && r.Method == http.MethodGet:
		// The claim token is sent via header to keep it out of access logs.
		claimToken := strings.TrimSpace(r.Header.Get("X-Veritra-Claim-Token"))
		if claimToken == "" {
			writeError(w, http.StatusBadRequest, "claim_token_required")
			return
		}
		sessionToken, sessionTokenHash, err := auth.NewToken()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "token_create_failed")
			return
		}
		linked, err := a.Store.ConsumeApprovedDeviceLink(r.Context(), linkID, auth.HashToken(claimToken), sessionTokenHash, time.Now().UTC().Add(30*24*time.Hour))
		if err != nil {
			switch {
			case errors.Is(err, storage.ErrDeviceLinkNotReady):
				writeJSON(w, http.StatusAccepted, map[string]string{"state": "pending_approval"})
			case errors.Is(err, storage.ErrDeviceLinkInvalid):
				writeError(w, http.StatusBadRequest, "invalid_device_link")
			default:
				writeError(w, http.StatusInternalServerError, "device_link_status_failed")
			}
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"account": linked.Account, "device": linked.Device, "token": sessionToken})
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

type createCommunityRequest struct {
	Name string `json:"name"`
}

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

func (a *API) uploadAttachment(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if r.Header.Get("X-Private-Messenger-Encrypted") != "1" {
		writeError(w, http.StatusBadRequest, "encrypted_upload_header_required")
		return
	}
	conversationID := optionalQuery(r, "conversation_id")
	if conversationID == nil {
		writeError(w, http.StatusBadRequest, "conversation_id_required")
		return
	}
	member, err := a.Store.IsConversationMember(r.Context(), *conversationID, principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if !member {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	metadata := json.RawMessage(r.Header.Get("X-Crypto-Metadata"))
	if len(metadata) == 0 {
		metadata = json.RawMessage(`{}`)
	}
	if !json.Valid(metadata) {
		writeError(w, http.StatusBadRequest, "invalid_crypto_metadata")
		return
	}
	storageKey, sha, size, err := a.Blobs.PutEncryptedBlob(r.Context(), http.MaxBytesReader(w, r.Body, 50<<20))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "upload_too_large")
			return
		}
		writeError(w, http.StatusInternalServerError, "upload_failed")
		return
	}
	attachment, err := a.Store.CreateAttachmentEnvelope(r.Context(), domain.AttachmentEnvelope{
		OwnerAccountID:   principal.AccountID,
		ConversationID:   conversationID,
		StorageKey:       storageKey,
		CiphertextSHA256: sha,
		SizeBytes:        size,
		CryptoMetadata:   metadata,
	})
	if err != nil {
		_ = a.Blobs.Delete(r.Context(), storageKey)
		writeError(w, http.StatusInternalServerError, "attachment_record_failed")
		return
	}
	writeJSON(w, http.StatusCreated, attachment)
}

func (a *API) listAttachments(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	attachments, err := a.Store.ListAttachments(r.Context(), principal.AccountID, limit)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"attachments": attachments})
}

func (a *API) attachmentSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/attachments/"), "/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	attachment, err := a.Store.AttachmentForAccount(r.Context(), id, principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	switch r.Method {
	case http.MethodGet:
		serveEncryptedBlob(w, r, a.Blobs, attachment.StorageKey, attachment.CiphertextSHA256, attachment.SizeBytes)
	case http.MethodDelete:
		if attachment.OwnerAccountID != principal.AccountID {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}
		deleted, err := a.Store.DeleteAttachment(r.Context(), id, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		if err := a.Blobs.Delete(r.Context(), deleted.StorageKey); err != nil {
			a.warn("attachment_blob_cleanup_failed", "attachment_id", deleted.ID, "err", err)
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

func (a *API) uploadBackup(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if r.Header.Get("X-Private-Messenger-Encrypted") != "1" {
		writeError(w, http.StatusBadRequest, "encrypted_upload_header_required")
		return
	}
	metadata := json.RawMessage(r.Header.Get("X-Key-Derivation-Metadata"))
	if len(metadata) == 0 {
		writeError(w, http.StatusBadRequest, "key_derivation_metadata_required")
		return
	}
	if !json.Valid(metadata) {
		writeError(w, http.StatusBadRequest, "invalid_key_derivation_metadata")
		return
	}
	storageKey, sha, size, err := a.Blobs.PutEncryptedBlob(r.Context(), http.MaxBytesReader(w, r.Body, 100<<20))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "upload_too_large")
			return
		}
		writeError(w, http.StatusInternalServerError, "backup_upload_failed")
		return
	}
	if err := a.Store.CreateBackupBlob(r.Context(), principal.AccountID, principal.DeviceID, storageKey, sha, size, metadata); err != nil {
		_ = a.Blobs.Delete(r.Context(), storageKey)
		writeError(w, http.StatusInternalServerError, "backup_record_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{"storage_key": storageKey, "ciphertext_sha256": sha, "size_bytes": size})
}

func (a *API) listBackups(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	backups, err := a.Store.ListBackups(r.Context(), principal.AccountID, limit)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"backups": backups})
}

func (a *API) backupSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/backups/"), "/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	backup, err := a.Store.BackupForAccount(r.Context(), id, principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	switch r.Method {
	case http.MethodGet:
		serveEncryptedBlob(w, r, a.Blobs, backup.StorageKey, backup.CiphertextSHA256, backup.SizeBytes)
	case http.MethodDelete:
		deleted, err := a.Store.DeleteBackup(r.Context(), id, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		if err := a.Blobs.Delete(r.Context(), deleted.StorageKey); err != nil {
			a.warn("backup_blob_cleanup_failed", "backup_id", deleted.ID, "err", err)
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

func serveEncryptedBlob(w http.ResponseWriter, r *http.Request, blobs uploads.Store, storageKey, sha string, size int64) {
	file, err := blobs.Open(storageKey)
	if err != nil {
		writeError(w, http.StatusNotFound, "blob_not_found")
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	if sha != "" {
		w.Header().Set("ETag", `"sha256-`+sha+`"`)
	}
	_, _ = io.Copy(w, file)
}

func (a *API) createPushSubscription(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		Provider string `json:"provider"`
		Endpoint string `json:"endpoint"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Provider == "" || req.Endpoint == "" {
		writeError(w, http.StatusBadRequest, "invalid_push_subscription")
		return
	}
	if err := a.Store.CreatePushSubscription(r.Context(), principal.AccountID, principal.DeviceID, req.Provider, req.Endpoint); err != nil {
		writeError(w, http.StatusInternalServerError, "push_subscription_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"status": "ok", "payload_policy": "generic_encrypted_event_only"})
}

func (a *API) deletePushSubscription(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := r.PathValue("id")
	if strings.TrimSpace(id) == "" {
		writeError(w, http.StatusBadRequest, "invalid_subscription_id")
		return
	}
	if err := a.Store.DisablePushSubscription(r.Context(), id, principal.AccountID); err != nil {
		handleStorageError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) createCall(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		ConversationID string          `json:"conversation_id"`
		Metadata       json.RawMessage `json:"metadata,omitempty"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if !validCallMetadata(req.Metadata) {
		writeError(w, http.StatusBadRequest, "invalid_call_metadata")
		return
	}
	call, err := a.Store.CreateCallSession(r.Context(), req.ConversationID, principal.AccountID, req.Metadata)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	eventID := a.saveSyncEvent(r.Context(), "call.signaling", nil, req.ConversationID, call)
	members := a.conversationMemberIDs(r.Context(), req.ConversationID)
	a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "call.signaling", ID: eventID, ConversationID: req.ConversationID, Payload: call, CreatedAt: time.Now().UTC()})
	writeJSON(w, http.StatusCreated, call)
}

func (a *API) listCalls(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	conversationID := strings.TrimSpace(r.URL.Query().Get("conversation_id"))
	if conversationID == "" {
		writeError(w, http.StatusBadRequest, "conversation_id_required")
		return
	}
	calls, err := a.Store.ListCallSessions(r.Context(), conversationID, principal.AccountID, 100)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"calls": calls})
}

func (a *API) callSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/calls/"), "/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] != "state" || r.Method != http.MethodPost {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	var req struct {
		State    string          `json:"state"`
		Metadata json.RawMessage `json:"metadata,omitempty"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if len(req.Metadata) > 0 && !validCallMetadata(req.Metadata) {
		writeError(w, http.StatusBadRequest, "invalid_call_metadata")
		return
	}
	call, err := a.Store.TransitionCallSession(r.Context(), parts[0], principal.AccountID, req.State, req.Metadata)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	eventID := a.saveSyncEvent(r.Context(), "call.state", nil, call.ConversationID, call)
	members := a.conversationMemberIDs(r.Context(), call.ConversationID)
	a.Hub.Publish(members, realtime.Event{Version: "v1", Type: "call.state", ID: eventID, ConversationID: call.ConversationID, Payload: call, CreatedAt: time.Now().UTC()})
	writeJSON(w, http.StatusOK, call)
}

func validCallMetadata(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	if len(raw) > 64<<10 || containsPlaintextMessageKey(raw) {
		return false
	}
	var envelope struct {
		Version    int    `json:"version"`
		Ciphertext []byte `json:"ciphertext"`
		Protocol   string `json:"protocol"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return false
	}
	return envelope.Version == 1 && len(envelope.Ciphertext) > 0 && len(envelope.Ciphertext) <= 48<<10 && strings.TrimSpace(envelope.Protocol) != ""
}

func (a *API) syncEvents(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	events, err := a.Store.ListSyncEvents(r.Context(), principal.AccountID, after, limit)
	if err != nil {
		if errors.Is(err, storage.ErrSyncCursorExpired) {
			epoch, oldest, latest, boundsErr := a.Store.SyncBounds(r.Context(), principal.AccountID)
			if boundsErr != nil {
				writeError(w, http.StatusInternalServerError, "sync_events_failed")
				return
			}
			writeJSON(w, http.StatusConflict, map[string]interface{}{"error": "full_resync_required", "sync_epoch": epoch, "oldest_event_id": oldest, "latest_event_id": latest})
			return
		}
		writeError(w, http.StatusInternalServerError, "sync_events_failed")
		return
	}
	epoch, oldest, latest, err := a.Store.SyncBounds(r.Context(), principal.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "sync_events_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"events": events, "sync_epoch": epoch, "oldest_event_id": oldest, "latest_event_id": latest})
}

func (a *API) searchMetadata(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	results, err := a.Store.SearchMetadata(r.Context(), principal.AccountID, r.URL.Query().Get("q"), limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_failed")
		return
	}
	normalizedLimit := normalizeLimit(limit, 20, 50)
	normalizedOffset := normalizeOffset(offset)
	response := map[string]interface{}{
		"results": results,
		"limit":   normalizedLimit,
		"offset":  normalizedOffset,
	}
	if len(results) == normalizedLimit {
		response["next_offset"] = normalizedOffset + len(results)
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *API) exportAccount(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit := normalizeLimit(messageQueryLimit(r), 1000, 5000)
	before := strings.TrimSpace(r.URL.Query().Get("before"))
	export, err := a.Store.ExportAccount(r.Context(), principal.AccountID, storage.ExportAccountOptions{Limit: limit, BeforeID: before})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	response := map[string]interface{}{
		"manifest_version": export.ManifestVersion,
		"account":          export.Account,
		"devices":          export.Devices,
		"conversations":    export.Conversations,
		"messages":         export.Messages,
		"categories":       export.Categories,
		"limit":            limit,
	}
	// Surface truncation explicitly so the client knows there may be more.
	if len(export.Messages) == limit && len(export.Messages) > 0 {
		response["next_before"] = export.Messages[len(export.Messages)-1].ID
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *API) deleteAccount(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	storageKeys, err := a.Store.DeleteAccountData(r.Context(), principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	var blobDeleteFailures int
	for _, storageKey := range storageKeys {
		if err := a.Blobs.Delete(r.Context(), storageKey); err != nil {
			blobDeleteFailures++
		}
	}
	if blobDeleteFailures > 0 {
		a.Log.Error("account_blob_cleanup_incomplete", "failed_count", blobDeleteFailures)
	}
	a.Hub.DisconnectAccount(principal.AccountID)
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.deleted", nil)
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) syncWebSocket(w http.ResponseWriter, r *http.Request) {
	principal, err := a.principalFromRequest(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	remoteIP := strings.TrimSpace(r.RemoteAddr)
	if host, _, splitErr := net.SplitHostPort(r.RemoteAddr); splitErr == nil {
		remoteIP = host
	}
	client, err := a.Hub.Register(principal.AccountID, principal.DeviceID, remoteIP)
	if err != nil {
		writeError(w, http.StatusTooManyRequests, "realtime_connection_limit")
		return
	}
	_ = realtime.ServeWebSocket(w, r, client, principal.ExpiresAt, func() { a.Hub.Unregister(client) })
}

type authedHandler func(http.ResponseWriter, *http.Request, domain.Principal)

func bearerToken(r *http.Request) string {
	authz := r.Header.Get("Authorization")
	const scheme = "Bearer "
	if len(authz) < len(scheme) || !strings.EqualFold(authz[:len(scheme)], scheme) {
		return ""
	}
	return strings.TrimSpace(authz[len(scheme):])
}

// logout revokes the caller's current session token.
func (a *API) logout(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	token := bearerToken(r)
	if token == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err := a.Store.DeleteSession(r.Context(), auth.HashToken(token)); err != nil {
		handleStorageError(w, err)
		return
	}
	a.Hub.DisconnectDevice(principal.AccountID, principal.DeviceID)
	a.recordAuditEvent(r.Context(), &principal.AccountID, "session.logout", map[string]string{"device_id": principal.DeviceID})
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) reauthenticate(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		Password     string `json:"password"`
		DeviceSecret string `json:"device_secret"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	passwordHash, deviceAuthHash, err := a.Store.ReauthenticationRecord(r.Context(), principal.AccountID, principal.DeviceID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	passwordOK := auth.VerifyPasswordOrDummy(passwordHash, req.Password)
	deviceOK := deviceAuthHash != "" && subtle.ConstantTimeCompare([]byte(auth.HashToken(req.DeviceSecret)), []byte(deviceAuthHash)) == 1
	if !passwordOK || !deviceOK {
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	token := bearerToken(r)
	if token == "" || a.Store.MarkSessionRecentlyAuthenticated(r.Context(), auth.HashToken(token)) != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	a.recordAuditEvent(r.Context(), &principal.AccountID, "session.reauthenticated", map[string]string{"device_id": principal.DeviceID})
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) changePassword(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		NewPassword string `json:"new_password"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	hash, err := auth.HashPassword(req.NewPassword)
	if err != nil {
		writeError(w, http.StatusBadRequest, "weak_password")
		return
	}
	token := bearerToken(r)
	if token == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err := a.Store.ChangePassword(r.Context(), principal.AccountID, auth.HashToken(token), hash); err != nil {
		handleStorageError(w, err)
		return
	}
	a.Hub.DisconnectAccountExceptDevice(principal.AccountID, principal.DeviceID)
	a.recordAuditEvent(r.Context(), &principal.AccountID, "account.password_changed", map[string]string{"device_id": principal.DeviceID})
	w.WriteHeader(http.StatusNoContent)
}

// logoutAll revokes every session for the account except the caller's current
// one, letting a user sign out other (possibly lost) devices without locking
// themselves out of the device making the request.
func (a *API) logoutAll(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	keep := ""
	if token := bearerToken(r); token != "" {
		keep = auth.HashToken(token)
	}
	if _, err := a.Store.DeleteAccountSessionsExcept(r.Context(), principal.AccountID, keep); err != nil {
		handleStorageError(w, err)
		return
	}
	a.Hub.DisconnectAccountExceptDevice(principal.AccountID, principal.DeviceID)
	a.recordAuditEvent(r.Context(), &principal.AccountID, "session.logout_others", map[string]string{"device_id": principal.DeviceID})
	w.WriteHeader(http.StatusNoContent)
}

// revokeDevice marks one of the caller's devices revoked and drops its sessions.
// Auth rejects the revoked device on its next request.
func (a *API) revokeDevice(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	deviceID := strings.TrimSpace(r.PathValue("id"))
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "invalid_device_id")
		return
	}
	if err := a.Store.RevokeDevice(r.Context(), principal.AccountID, deviceID); err != nil {
		handleStorageError(w, err)
		return
	}
	a.Hub.DisconnectDevice(principal.AccountID, deviceID)
	a.recordAuditEvent(r.Context(), &principal.AccountID, "device.revoked", map[string]string{"device_id": deviceID})
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) withAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		principal, err := a.principalFromRequest(r)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
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

func validUsername(username string) bool {
	username = strings.TrimSpace(username)
	if len(username) < 3 || len(username) > 32 {
		return false
	}
	for _, r := range username {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_' && r != '-' {
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
