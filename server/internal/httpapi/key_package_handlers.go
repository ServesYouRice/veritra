package httpapi

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/storage"
)

const openMLSCiphersuite = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"

func (a *API) publishDeviceKeyPackages(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	var request struct {
		KeyPackages []struct {
			KeyPackage  []byte    `json:"key_package"`
			Ciphersuite string    `json:"ciphersuite"`
			ExpiresAt   time.Time `json:"expires_at"`
		} `json:"key_packages"`
	}
	if !decodeJSON(w, r, &request) {
		return
	}
	if len(request.KeyPackages) == 0 || len(request.KeyPackages) > 10 {
		writeError(w, http.StatusBadRequest, "invalid_key_packages")
		return
	}
	now := time.Now().UTC()
	inputs := make([]storage.NewDeviceKeyPackage, 0, len(request.KeyPackages))
	for _, item := range request.KeyPackages {
		if len(item.KeyPackage) < 64 || len(item.KeyPackage) > 48*1024 ||
			strings.TrimSpace(item.Ciphersuite) != openMLSCiphersuite ||
			item.ExpiresAt.Before(now.Add(time.Hour)) || item.ExpiresAt.After(now.Add(30*24*time.Hour)) {
			writeError(w, http.StatusBadRequest, "invalid_key_packages")
			return
		}
		inputs = append(inputs, storage.NewDeviceKeyPackage{KeyPackage: item.KeyPackage, Ciphersuite: openMLSCiphersuite, ExpiresAt: item.ExpiresAt.UTC()})
	}
	created, err := a.Store.PublishDeviceKeyPackages(r.Context(), principal.DeviceID, inputs)
	if errors.Is(err, storage.ErrStorageQuota) {
		writeError(w, http.StatusConflict, "key_package_quota_exceeded")
		return
	}
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"key_packages": created})
}

func (a *API) claimConversationKeyPackages(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	conversationID := strings.TrimSpace(r.PathValue("id"))
	if conversationID == "" {
		writeError(w, http.StatusBadRequest, "invalid_conversation_id")
		return
	}
	packages, err := a.Store.ClaimConversationKeyPackages(r.Context(), conversationID, principal.AccountID, principal.DeviceID)
	if errors.Is(err, storage.ErrKeyPackageUnavailable) {
		writeError(w, http.StatusConflict, "key_package_unavailable")
		return
	}
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"key_packages": packages})
}
