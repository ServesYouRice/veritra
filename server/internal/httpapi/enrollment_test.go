package httpapi_test

import (
	"context"
	"encoding/json"
	"net/http"
	"path/filepath"
	"testing"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
)

func TestOwnerEnrollmentBindsReservedIdentityAndCredentialSignature(t *testing.T) {
	dir := t.TempDir()
	application, err := app.New(context.Background(), config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
		SetupToken:   "test-setup-token",
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	enrollment := reserveEnrollment(t, handler, "/api/v1/setup/owner/enrollment", "")
	body := map[string]interface{}{
		"instance_name":      "Test Messenger",
		"username":           "owner",
		"password":           "owner-password-123",
		"device_name":        "owner phone",
		"device_key_package": make([]byte, 64),
	}
	addEnrollmentProof(body, enrollment)
	validSignature := append([]byte(nil), body["challenge_signature"].([]byte)...)

	tampered := append([]byte(nil), validSignature...)
	tampered[0] ^= 1
	body["challenge_signature"] = tampered
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body)
	if status != http.StatusBadRequest {
		t.Fatalf("tampered enrollment status=%d body=%s", status, response)
	}

	body["challenge_signature"] = validSignature
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body)
	if status != http.StatusCreated {
		t.Fatalf("valid enrollment status=%d body=%s", status, response)
	}
	var created struct {
		Account struct {
			ID string `json:"id"`
		} `json:"account"`
		Device struct {
			ID         string `json:"id"`
			SigningKey []byte `json:"signing_key"`
		} `json:"device"`
	}
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatalf("decode owner response: %v", err)
	}
	if created.Account.ID != enrollment.AccountID || created.Device.ID != enrollment.DeviceID {
		t.Fatalf("reserved identity changed: enrollment=%#v response=%s", enrollment, response)
	}
	if string(created.Device.SigningKey) != string(enrollment.SigningKey) {
		t.Fatalf("credential signing key was not stored: %s", response)
	}

	status, _ = doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body)
	if status == http.StatusCreated {
		t.Fatal("consumed enrollment reservation was replayed")
	}
}
