package httpapi

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
	"private-messenger/server/websetup"
)

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
	EnrollmentReservationID string  `json:"enrollment_reservation_id"`
	InstanceName            string  `json:"instance_name"`
	Username                string  `json:"username"`
	Email                   *string `json:"email,omitempty"`
	Password                string  `json:"password"`
	DeviceName              string  `json:"device_name"`
	DeviceKeyPackage        []byte  `json:"device_key_package"`
	SigningKey              []byte  `json:"signing_key"`
	ChallengeSignature      []byte  `json:"challenge_signature"`
}

func (a *API) reserveOwnerEnrollment(w http.ResponseWriter, r *http.Request) {
	if !a.setupAuthorized(r) {
		writeError(w, http.StatusForbidden, "setup_authorization_required")
		return
	}
	reservation, err := a.Store.ReserveOwnerEnrollment(r.Context())
	if errors.Is(err, storage.ErrAlreadySetup) {
		writeError(w, http.StatusConflict, "already_setup")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "enrollment_reservation_failed")
		return
	}
	writeJSON(w, http.StatusCreated, enrollmentReservationResponse(reservation))
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
	if len(req.DeviceKeyPackage) < 64 || len(req.DeviceKeyPackage) > 48<<10 {
		writeError(w, http.StatusBadRequest, "invalid_device_key_package")
		return
	}
	reservation, ok := a.verifyEnrollment(
		r, req.EnrollmentReservationID, "owner", req.SigningKey, req.DeviceKeyPackage, req.ChallengeSignature,
	)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
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
		EnrollmentReservationID: reservation.ID,
		InstanceName:            req.InstanceName,
		Username:                req.Username,
		Email:                   req.Email,
		PasswordHash:            passwordHash,
		DeviceName:              req.DeviceName,
		KeyPackage:              req.DeviceKeyPackage,
		SigningKey:              req.SigningKey,
		DeviceAuthHash:          deviceAuthHash,
		SessionHash:             tokenHash,
		SessionExpiry:           time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		if errors.Is(err, storage.ErrAlreadySetup) {
			writeError(w, http.StatusConflict, "already_setup")
			return
		}
		if errors.Is(err, storage.ErrEnrollmentInvalid) {
			writeError(w, http.StatusBadRequest, "invalid_enrollment")
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
	EnrollmentReservationID string  `json:"enrollment_reservation_id"`
	InviteCode              string  `json:"invite_code"`
	Username                string  `json:"username"`
	Email                   *string `json:"email,omitempty"`
	Password                string  `json:"password"`
	DeviceName              string  `json:"device_name"`
	DeviceKeyPackage        []byte  `json:"device_key_package"`
	SigningKey              []byte  `json:"signing_key"`
	ChallengeSignature      []byte  `json:"challenge_signature"`
}

func (a *API) reserveRegistrationEnrollment(w http.ResponseWriter, r *http.Request) {
	var req struct {
		InviteCode string `json:"invite_code"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	reservation, err := a.Store.ReserveRegistrationEnrollment(r.Context(), req.InviteCode)
	if errors.Is(err, storage.ErrInviteInvalid) {
		writeError(w, http.StatusBadRequest, "invalid_invite")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "enrollment_reservation_failed")
		return
	}
	writeJSON(w, http.StatusCreated, enrollmentReservationResponse(reservation))
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
	if len(req.DeviceKeyPackage) < 64 || len(req.DeviceKeyPackage) > 48<<10 {
		writeError(w, http.StatusBadRequest, "invalid_device_key_package")
		return
	}
	reservation, ok := a.verifyEnrollment(
		r, req.EnrollmentReservationID, "register", req.SigningKey, req.DeviceKeyPackage, req.ChallengeSignature,
	)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
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
		EnrollmentReservationID: reservation.ID,
		InviteCode:              req.InviteCode,
		Username:                req.Username,
		Email:                   req.Email,
		PasswordHash:            passwordHash,
		DeviceName:              req.DeviceName,
		KeyPackage:              req.DeviceKeyPackage,
		SigningKey:              req.SigningKey,
		DeviceAuthHash:          deviceAuthHash,
		SessionHash:             tokenHash,
		SessionExpiry:           time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		if errors.Is(err, storage.ErrInviteInvalid) {
			writeError(w, http.StatusBadRequest, "invalid_invite")
			return
		}
		if errors.Is(err, storage.ErrEnrollmentInvalid) {
			writeError(w, http.StatusBadRequest, "invalid_enrollment")
			return
		}
		writeError(w, http.StatusInternalServerError, "register_failed")
		return
	}
	a.recordAuditEvent(r.Context(), &created.Account.ID, "account.registered", map[string]string{"device_id": created.Device.ID})
	writeJSON(w, http.StatusCreated, map[string]interface{}{"account": created.Account, "device": created.Device, "token": token, "device_secret": deviceSecret})
}

func enrollmentReservationResponse(reservation storage.EnrollmentReservation) map[string]interface{} {
	return map[string]interface{}{
		"id":         reservation.ID,
		"account_id": reservation.AccountID,
		"device_id":  reservation.DeviceID,
		"challenge":  reservation.Challenge,
		"expires_at": reservation.ExpiresAt,
	}
}

func (a *API) verifyEnrollment(
	r *http.Request,
	reservationID string,
	kind string,
	signingKey []byte,
	keyPackage []byte,
	signature []byte,
) (storage.EnrollmentReservation, bool) {
	if len(signingKey) != ed25519.PublicKeySize || len(signature) != ed25519.SignatureSize {
		return storage.EnrollmentReservation{}, false
	}
	reservation, err := a.Store.EnrollmentReservation(r.Context(), reservationID)
	if err != nil || reservation.Kind != kind {
		return storage.EnrollmentReservation{}, false
	}
	proof := enrollmentProofMessage(reservation.Challenge, signingKey, keyPackage)
	if !ed25519.Verify(ed25519.PublicKey(signingKey), proof, signature) {
		return storage.EnrollmentReservation{}, false
	}
	return reservation, true
}

func enrollmentProofMessage(challenge, signingKey, keyPackage []byte) []byte {
	keyPackageHash := sha256.Sum256(keyPackage)
	proof := []byte("veritra-enrollment-proof-v1")
	var challengeLength [2]byte
	binary.BigEndian.PutUint16(challengeLength[:], uint16(len(challenge)))
	proof = append(proof, challengeLength[:]...)
	proof = append(proof, challenge...)
	proof = append(proof, signingKey...)
	proof = append(proof, keyPackageHash[:]...)
	return proof
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
	EnrollmentReservationID string `json:"enrollment_reservation_id"`
	Code                    string `json:"code"`
	DeviceName              string `json:"device_name"`
	DeviceKeyPackage        []byte `json:"device_key_package"`
	SigningKey              []byte `json:"signing_key,omitempty"`
	ChallengeSignature      []byte `json:"challenge_signature"`
}

func (a *API) reserveDeviceLinkEnrollment(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	reservation, err := a.Store.ReserveDeviceLinkEnrollment(r.Context(), req.Code)
	if errors.Is(err, storage.ErrDeviceLinkInvalid) {
		writeError(w, http.StatusBadRequest, "invalid_device_link")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "enrollment_reservation_failed")
		return
	}
	writeJSON(w, http.StatusCreated, enrollmentReservationResponse(reservation))
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
	if len(req.DeviceKeyPackage) < 64 || len(req.DeviceKeyPackage) > 48<<10 {
		writeError(w, http.StatusBadRequest, "invalid_device_key_package")
		return
	}
	if len(req.SigningKey) != ed25519.PublicKeySize || len(req.ChallengeSignature) != ed25519.SignatureSize {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
		return
	}
	reservation, err := a.Store.DeviceLinkEnrollment(
		r.Context(), req.Code, req.EnrollmentReservationID,
	)
	if err != nil || !ed25519.Verify(
		ed25519.PublicKey(req.SigningKey),
		enrollmentProofMessage(reservation.Challenge, req.SigningKey, req.DeviceKeyPackage),
		req.ChallengeSignature,
	) {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
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
