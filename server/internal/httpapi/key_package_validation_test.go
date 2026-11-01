package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/mlswire/mlswiretest"
	"private-messenger/server/internal/storage"
)

// badKeyPackages are uploads that are not one MLS KeyPackage: what test
// helpers used to send, and a real package cut short or with a byte added.
func badKeyPackages() map[string][]byte {
	valid := mlswiretest.OpenMLSKeyPackage()
	return map[string][]byte{
		"64 zero bytes": make([]byte, 64),
		"truncated":     valid[:len(valid)-1],
		"trailing byte": append(append([]byte(nil), valid...), 0),
	}
}

func requireAPIError(t *testing.T, label string, status int, response []byte, wantStatus int, wantCode string) {
	t.Helper()
	if status != wantStatus || !jsonErrorIs(response, wantCode) {
		t.Fatalf("%s: status=%d body=%s, want %d %s", label, status, response, wantStatus, wantCode)
	}
}

// Every route that takes a device key package refuses bytes that do not
// parse as an RFC 9420 KeyPackage, and accepts the client's real encoding.
func TestDeviceKeyPackageStructuralValidation(t *testing.T) {
	t.Run("setup", func(t *testing.T) {
		application := openRecoveryApp(t, t.TempDir(), "")
		t.Cleanup(func() { _ = application.Close() })
		handler := application.Handler()
		enrollment := reserveEnrollment(t, handler, "/api/v1/setup/owner/enrollment", "")
		body := func(keyPackage []byte) map[string]interface{} {
			b := map[string]interface{}{
				"instance_name": "Test Messenger", "username": "owner", "password": "owner-password-123",
				"device_name": "owner phone", "device_key_package": keyPackage,
			}
			addEnrollmentProof(b, enrollment)
			return b
		}
		for name, keyPackage := range badKeyPackages() {
			status, response := doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body(keyPackage))
			requireAPIError(t, name, status, response, http.StatusBadRequest, "invalid_device_key_package")
		}
		status, response := doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body(mlswiretest.OpenMLSKeyPackage()))
		if status != http.StatusCreated {
			t.Fatalf("client key package: setup status=%d body=%s", status, response)
		}
	})

	t.Run("register", func(t *testing.T) {
		handler, ownerToken, _ := newTestHandlerWithOwner(t)
		status, response := doJSON(t, handler, http.MethodPost, "/api/v1/invites", ownerToken, map[string]interface{}{"max_uses": 1})
		if status != http.StatusCreated {
			t.Fatalf("create invite status=%d body=%s", status, response)
		}
		var invite struct {
			Code string `json:"code"`
		}
		if err := json.Unmarshal(response, &invite); err != nil {
			t.Fatal(err)
		}
		enrollment := reserveEnrollment(t, handler, "/api/v1/register/enrollment", invite.Code)
		body := func(keyPackage []byte) map[string]interface{} {
			b := map[string]interface{}{
				"invite_code": invite.Code, "username": "member", "password": "member-password-123",
				"device_name": "member phone", "device_key_package": keyPackage,
			}
			addEnrollmentProof(b, enrollment)
			return b
		}
		for name, keyPackage := range badKeyPackages() {
			status, response := doJSON(t, handler, http.MethodPost, "/api/v1/register", "", body(keyPackage))
			requireAPIError(t, name, status, response, http.StatusBadRequest, "invalid_device_key_package")
		}
		status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register", "", body(mlswiretest.OpenMLSKeyPackage()))
		if status != http.StatusCreated {
			t.Fatalf("client key package: register status=%d body=%s", status, response)
		}
	})

	t.Run("device link claim", func(t *testing.T) {
		handler, ownerToken, _ := newTestHandlerWithOwner(t)
		status, response := doJSON(t, handler, http.MethodPost, "/api/v1/device-links", ownerToken, map[string]interface{}{"code": strings.Repeat("b", 64)})
		if status != http.StatusCreated {
			t.Fatalf("create device link status=%d body=%s", status, response)
		}
		var created struct {
			DeviceLink struct {
				Code string `json:"code"`
			} `json:"device_link"`
		}
		if err := json.Unmarshal(response, &created); err != nil {
			t.Fatal(err)
		}
		enrollment := reserveEnrollment(t, handler, "/api/v1/device-links/claim-enrollment", created.DeviceLink.Code)
		body := func(keyPackage []byte) map[string]interface{} {
			b := map[string]interface{}{
				"code": created.DeviceLink.Code, "device_name": "linked tablet", "device_key_package": keyPackage,
				"transcript_hash": bytes.Repeat([]byte{7}, 32), "claim_tag": bytes.Repeat([]byte{8}, 32),
			}
			addEnrollmentProof(b, enrollment)
			return b
		}
		for name, keyPackage := range badKeyPackages() {
			status, response := doJSON(t, handler, http.MethodPost, "/api/v1/device-links/claim", "", body(keyPackage))
			requireAPIError(t, name, status, response, http.StatusBadRequest, "invalid_device_key_package")
		}
		status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/claim", "", body(mlswiretest.OpenMLSKeyPackage()))
		if status != http.StatusAccepted {
			t.Fatalf("client key package: claim status=%d body=%s", status, response)
		}
	})

	// The v3 claim and the recovery claim check the package before the
	// reservation or any proof, so the rest of the request may be a dummy;
	// their valid paths are covered by the v3 and recovery fixtures, which
	// upload a synthetic package.
	t.Run("device link v3 claim", func(t *testing.T) {
		handler, _, _ := newTestHandlerWithOwner(t)
		for name, keyPackage := range badKeyPackages() {
			claim := storage.DeviceLinkV3ClaimInput{ProtocolVersion: storage.DeviceLinkV3Protocol, DeviceName: "phone", DeviceKeyPackage: keyPackage}
			status, response := doJSON(t, handler, http.MethodPost, v3Base+"/claim", "", claim)
			requireAPIError(t, name, status, response, http.StatusBadRequest, "invalid_device_key_package")
		}
	})

	t.Run("account recovery claim", func(t *testing.T) {
		f := newRecoveryFixture(t, recoveryTestOrigin)
		for name, keyPackage := range badKeyPackages() {
			status, response := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", map[string]interface{}{
				"enrollment_reservation_id": "enroll_x", "password": "owner-password-123", "device_name": "new phone",
				"device_key_package": keyPackage, "signing_key": make([]byte, 32),
				"challenge_signature": make([]byte, 64), "recovery_signature": make([]byte, 64),
			}, nil)
			requireAPIError(t, name, status, response, http.StatusBadRequest, "invalid_device_key_package")
		}
	})

	t.Run("key package publish", func(t *testing.T) {
		handler, ownerToken, _ := newTestHandlerWithOwner(t)
		publish := func(keyPackage []byte) (int, []byte) {
			return doJSON(t, handler, http.MethodPost, "/api/v1/devices/me/key-packages", ownerToken, map[string]interface{}{
				"key_packages": []map[string]interface{}{{
					"key_package": keyPackage, "ciphersuite": "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
					"expires_at": time.Now().UTC().Add(7 * 24 * time.Hour),
				}},
			})
		}
		for name, keyPackage := range badKeyPackages() {
			status, response := publish(keyPackage)
			requireAPIError(t, name, status, response, http.StatusBadRequest, "invalid_key_packages")
		}
		if status, response := publish(mlswiretest.OpenMLSKeyPackage()); status != http.StatusCreated {
			t.Fatalf("client key package: publish status=%d body=%s", status, response)
		}
		if status, response := publish(mlswiretest.KeyPackage()); status != http.StatusCreated {
			t.Fatalf("synthetic key package: publish status=%d body=%s", status, response)
		}
	})
}
