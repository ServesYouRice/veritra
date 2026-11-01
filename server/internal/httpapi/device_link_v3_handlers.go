package httpapi

import (
	"encoding/base64"
	"errors"
	"net/http"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

const deviceLinkV3Prefix = "/api/v1/device-links/v3"

func (a *API) registerDeviceLinkV3Routes(mux *http.ServeMux) {
	a.registerHistoryTransferRoutes(mux)
	mux.HandleFunc("POST "+deviceLinkV3Prefix, a.withRecentAuth(a.createDeviceLinkV3))
	mux.HandleFunc("POST "+deviceLinkV3Prefix+"/claim-enrollment", a.reserveDeviceLinkV3)
	mux.HandleFunc("POST "+deviceLinkV3Prefix+"/claim", a.claimDeviceLinkV3)
	mux.HandleFunc("GET "+deviceLinkV3Prefix+"/{id}", a.withAuth(a.getDeviceLinkV3))
	mux.HandleFunc("DELETE "+deviceLinkV3Prefix+"/{id}", a.withRecentAuth(a.cancelDeviceLinkV3))
	mux.HandleFunc("POST "+deviceLinkV3Prefix+"/{id}/approve", a.withRecentAuth(a.approveDeviceLinkV3))
	mux.HandleFunc("GET "+deviceLinkV3Prefix+"/{id}/claim-status", a.deviceLinkV3ClaimStatus)
	mux.HandleFunc("POST "+deviceLinkV3Prefix+"/{id}/complete", a.completeDeviceLinkV3)
}

func (a *API) createDeviceLinkV3(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		Code             string `json:"code"`
		ServerOrigin     string `json:"server_origin"`
		ProtocolVersion  string `json:"protocol_version"`
		ExpiresInSeconds int64  `json:"expires_in_seconds,omitempty"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ProtocolVersion != storage.DeviceLinkV3Protocol || req.ExpiresInSeconds < 0 || req.ExpiresInSeconds > 1800 || principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "invalid_device_link")
		return
	}
	link, err := a.Store.CreateDeviceLinkV3(r.Context(), principal.AccountID, principal.DeviceID, req.Code, req.ServerOrigin, time.Duration(req.ExpiresInSeconds)*time.Second)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{"device_link": link})
}

func (a *API) reserveDeviceLinkV3(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code                 string `json:"code"`
		ProtocolVersion      string `json:"protocol_version"`
		ReservationRequestID string `json:"reservation_request_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ProtocolVersion != storage.DeviceLinkV3Protocol {
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
		return
	}
	reservation, err := a.Store.ReserveDeviceLinkV3(r.Context(), req.Code, req.ReservationRequestID)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	response := enrollmentReservationResponse(reservation)
	response["expires_at"] = reservation.ExpiresAt
	writeJSON(w, http.StatusCreated, response)
}

func (a *API) claimDeviceLinkV3(w http.ResponseWriter, r *http.Request) {
	var req storage.DeviceLinkV3ClaimInput
	if !decodeJSON(w, r, &req) {
		return
	}
	if isReservedNonProductionKeyPackage(req.DeviceKeyPackage) {
		writeError(w, http.StatusBadRequest, "non_production_device_key_package")
		return
	}
	if !validDeviceKeyPackage(req.DeviceKeyPackage) {
		writeError(w, http.StatusBadRequest, "invalid_device_key_package")
		return
	}
	link, err := a.Store.ClaimDeviceLinkV3(r.Context(), req)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]interface{}{"device_link": link})
}

func (a *API) getDeviceLinkV3(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	link, err := a.Store.DeviceLinkV3ForSource(r.Context(), r.PathValue("id"), principal.AccountID, principal.DeviceID)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"device_link": link})
}

func (a *API) approveDeviceLinkV3(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		ProtocolVersion  string `json:"protocol_version"`
		ClaimRequestHash string `json:"claim_request_hash"`
		TranscriptHash   []byte `json:"transcript_hash"`
		ApprovalTag      []byte `json:"approval_tag"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ProtocolVersion != storage.DeviceLinkV3Protocol {
		writeError(w, http.StatusBadRequest, "invalid_device_link")
		return
	}
	link, device, eventID, err := a.Store.ApproveDeviceLinkV3(r.Context(), r.PathValue("id"), principal.AccountID, principal.DeviceID, req.ClaimRequestHash, req.TranscriptHash, req.ApprovalTag)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	if eventID != 0 {
		payload := map[string]interface{}{"device": device, "device_link_id": link.ID}
		a.publishCommittedEvent(r.Context(), []string{principal.AccountID}, realtime.Event{Version: "v1", Type: "device.updated", ID: eventID, Payload: payload, CreatedAt: time.Now().UTC()})
		a.recordAuditEvent(r.Context(), &principal.AccountID, "device_link.approved", map[string]string{"link_id": link.ID, "device_id": device.ID})
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"device_link": link, "device": device})
}

func deviceLinkV3ClaimTokenHash(w http.ResponseWriter, r *http.Request) (string, bool) {
	value := r.Header.Get("X-Veritra-Claim-Token")
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(decoded) != 32 || base64.RawURLEncoding.EncodeToString(decoded) != value {
		writeError(w, http.StatusBadRequest, "claim_token_required")
		return "", false
	}
	return auth.HashToken(value), true
}

func (a *API) deviceLinkV3ClaimStatus(w http.ResponseWriter, r *http.Request) {
	hash, ok := deviceLinkV3ClaimTokenHash(w, r)
	if !ok {
		return
	}
	link, err := a.Store.DeviceLinkV3ForClaim(r.Context(), r.PathValue("id"), hash)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]interface{}{"device_link": link})
}

func (a *API) completeDeviceLinkV3(w http.ResponseWriter, r *http.Request) {
	hash, ok := deviceLinkV3ClaimTokenHash(w, r)
	if !ok {
		return
	}
	var req struct {
		ProtocolVersion         string `json:"protocol_version"`
		ClaimRequestHash        string `json:"claim_request_hash"`
		TranscriptHash          []byte `json:"transcript_hash"`
		InitialSessionTokenHash string `json:"initial_session_token_hash"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.ProtocolVersion != storage.DeviceLinkV3Protocol {
		writeError(w, http.StatusBadRequest, "invalid_device_link")
		return
	}
	receipt, tag, err := a.Store.CompleteDeviceLinkV3(r.Context(), r.PathValue("id"), hash, req.ClaimRequestHash, req.InitialSessionTokenHash, req.TranscriptHash)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]interface{}{"completion": receipt, "approval_tag": tag})
}

func (a *API) cancelDeviceLinkV3(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if err := a.Store.CancelDeviceLinkV3(r.Context(), r.PathValue("id"), principal.AccountID, principal.DeviceID); err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": "revoked"})
}

func (a *API) deviceLinkV3Error(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, storage.ErrEnrollmentInvalid):
		writeError(w, http.StatusBadRequest, "invalid_enrollment")
	case errors.Is(err, storage.ErrDeviceLinkVerificationFailed):
		writeError(w, http.StatusBadRequest, "transcript_mismatch")
	case errors.Is(err, storage.ErrDeviceLinkNotReady):
		writeJSON(w, http.StatusConflict, map[string]string{"error": "idempotency_conflict", "state": "pending_approval"})
	case errors.Is(err, storage.ErrDeviceLinkSessionUnavailable):
		writeJSON(w, http.StatusGone, map[string]string{"error": "invalid_device_link", "state": "session_unavailable"})
	default:
		handleStorageError(w, err)
	}
}
