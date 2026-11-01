package httpapi_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/mlswire/mlswiretest"
)

const rotateHeader = "X-Veritra-Rotate-Session"

type rotationOwner struct {
	handler      http.Handler
	db           *sql.DB
	token        string
	deviceID     string
	deviceSecret string
}

func newRotationOwner(t *testing.T) rotationOwner {
	t.Helper()
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "private-messenger.db")
	application, err := app.New(context.Background(), config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: dbPath,
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
		"device_key_package": mlswiretest.KeyPackage(),
	}
	addEnrollmentProof(body, enrollment)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body)
	if status != http.StatusCreated {
		t.Fatalf("setup owner status=%d body=%s", status, response)
	}
	var decoded struct {
		Token        string `json:"token"`
		DeviceSecret string `json:"device_secret"`
		Device       struct {
			ID string `json:"id"`
		} `json:"device"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil || decoded.Token == "" || decoded.DeviceSecret == "" {
		t.Fatalf("decode setup response: %v %s", err, response)
	}
	return rotationOwner{handler: handler, db: openSessionTestDB(t, dbPath), token: decoded.Token, deviceID: decoded.Device.ID, deviceSecret: decoded.DeviceSecret}
}

func doRequest(t *testing.T, handler http.Handler, method, path, token string, headers map[string]string, body interface{}) (int, []byte) {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

func (o rotationOwner) reauth(t *testing.T, token, password string, rotate bool) (int, []byte) {
	t.Helper()
	headers := map[string]string{}
	if rotate {
		headers[rotateHeader] = "1"
	}
	return doRequest(t, o.handler, http.MethodPost, "/api/v1/auth/reauth", token, headers, map[string]string{"password": password, "device_secret": o.deviceSecret})
}

func (o rotationOwner) rotate(t *testing.T, token string) string {
	t.Helper()
	status, response := o.reauth(t, token, "owner-password-123", true)
	if status != http.StatusOK {
		t.Fatalf("rotating reauth status=%d body=%s", status, response)
	}
	var decoded struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil || decoded.Token == "" || decoded.Token == token {
		t.Fatalf("rotating reauth body=%s err=%v", response, err)
	}
	return decoded.Token
}

func (o rotationOwner) status(t *testing.T, method, path, token string) int {
	t.Helper()
	status, _ := doJSON(t, o.handler, method, path, token, nil)
	return status
}

func TestReauthRotationIssuesANewTokenAndAGraceForTheOldOne(t *testing.T) {
	owner := newRotationOwner(t)
	newToken := owner.rotate(t, owner.token)

	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", newToken); got != http.StatusOK {
		t.Fatalf("new token status=%d", got)
	}
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", owner.token); got != http.StatusOK {
		t.Fatalf("old token inside grace status=%d", got)
	}
	status, response := doJSON(t, owner.handler, http.MethodPost, "/api/v1/auth/logout-all", owner.token, map[string]string{})
	if status != http.StatusForbidden || !bytes.Contains(response, []byte("recent_auth_required")) {
		t.Fatalf("old token used recent auth: status=%d body=%s", status, response)
	}
	if status, _ := owner.reauth(t, owner.token, "owner-password-123", false); status != http.StatusUnauthorized {
		t.Fatalf("non-rotating reauth with old token status=%d", status)
	}
	if got := owner.status(t, http.MethodPost, "/api/v1/auth/logout-all", newToken); got != http.StatusNoContent {
		t.Fatalf("logout-all with new token status=%d", got)
	}
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", owner.token); got != http.StatusUnauthorized {
		t.Fatalf("old token after logout-all status=%d", got)
	}
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", newToken); got != http.StatusOK {
		t.Fatalf("kept token after logout-all status=%d", got)
	}
}

func TestReauthWithoutRotationKeepsTheTokenForOlderClients(t *testing.T) {
	owner := newRotationOwner(t)
	status, response := owner.reauth(t, owner.token, "owner-password-123", false)
	if status != http.StatusNoContent || len(bytes.TrimSpace(response)) != 0 {
		t.Fatalf("non-rotating reauth status=%d body=%s", status, response)
	}
	if got := owner.status(t, http.MethodPost, "/api/v1/auth/logout-all", owner.token); got != http.StatusNoContent {
		t.Fatalf("recently authenticated token status=%d", got)
	}
}

func TestRotationNeedsBothCredentials(t *testing.T) {
	owner := newRotationOwner(t)
	if status, _ := owner.reauth(t, owner.token, "wrong-password-123", true); status != http.StatusUnauthorized {
		t.Fatalf("wrong password rotation status=%d", status)
	}
	status, _ := doRequest(t, owner.handler, http.MethodPost, "/api/v1/auth/reauth", owner.token, map[string]string{rotateHeader: "1"},
		map[string]string{"password": "owner-password-123", "device_secret": "wrong-device-secret"})
	if status != http.StatusUnauthorized {
		t.Fatalf("wrong device secret rotation status=%d", status)
	}
	var previous sql.NullString
	if err := owner.db.QueryRow(`SELECT previous_token_hash FROM sessions`).Scan(&previous); err != nil || previous.Valid {
		t.Fatalf("failed reauth rotated the session: previous=%v err=%v", previous, err)
	}
}

func TestRotatedOutTokenFailsAfterTheGrace(t *testing.T) {
	owner := newRotationOwner(t)
	newToken := owner.rotate(t, owner.token)
	if _, err := owner.db.Exec(`UPDATE sessions SET previous_expires_at = ?`, storedTime(time.Now().UTC().Add(-time.Second))); err != nil {
		t.Fatalf("end grace: %v", err)
	}
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", owner.token); got != http.StatusUnauthorized {
		t.Fatalf("old token after grace status=%d", got)
	}
	if status, _ := owner.reauth(t, owner.token, "owner-password-123", true); status != http.StatusUnauthorized {
		t.Fatalf("rotation from an expired token status=%d", status)
	}
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", newToken); got != http.StatusOK {
		t.Fatalf("new token status=%d", got)
	}
}

func TestLostRotationResponseCanBeRetriedWithTheOldToken(t *testing.T) {
	owner := newRotationOwner(t)
	lost := owner.rotate(t, owner.token)
	retried := owner.rotate(t, owner.token)
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", lost); got != http.StatusUnauthorized {
		t.Fatalf("unreceived token status=%d", got)
	}
	if got := owner.status(t, http.MethodPost, "/api/v1/auth/logout-all", retried); got != http.StatusNoContent {
		t.Fatalf("retried token status=%d", got)
	}
}

func TestRevocationAfterRotationRevokesBothTokens(t *testing.T) {
	for name, revoke := range map[string]func(t *testing.T, owner rotationOwner, oldToken, newToken string){
		"logout_old_token": func(t *testing.T, owner rotationOwner, oldToken, _ string) {
			if got := owner.status(t, http.MethodPost, "/api/v1/auth/logout", oldToken); got != http.StatusNoContent {
				t.Fatalf("logout status=%d", got)
			}
		},
		"logout_new_token": func(t *testing.T, owner rotationOwner, _, newToken string) {
			if got := owner.status(t, http.MethodPost, "/api/v1/auth/logout", newToken); got != http.StatusNoContent {
				t.Fatalf("logout status=%d", got)
			}
		},
		"device_removed": func(t *testing.T, owner rotationOwner, _, newToken string) {
			if got := owner.status(t, http.MethodDelete, "/api/v1/devices/"+owner.deviceID, newToken); got != http.StatusNoContent {
				t.Fatalf("revoke status=%d", got)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			owner := newRotationOwner(t)
			newToken := owner.rotate(t, owner.token)
			revoke(t, owner, owner.token, newToken)
			for _, token := range []string{owner.token, newToken} {
				if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", token); got != http.StatusUnauthorized {
					t.Fatalf("token after %s status=%d", name, got)
				}
			}
		})
	}

	owner := newRotationOwner(t)
	newToken := owner.rotate(t, owner.token)
	status, response := doJSON(t, owner.handler, http.MethodPost, "/api/v1/account/password", newToken, map[string]string{"new_password": "owner-password-456"})
	if status != http.StatusNoContent {
		t.Fatalf("change password status=%d body=%s", status, response)
	}
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", owner.token); got != http.StatusUnauthorized {
		t.Fatalf("old token after password change status=%d", got)
	}
	if got := owner.status(t, http.MethodGet, "/api/v1/devices/me", newToken); got != http.StatusOK {
		t.Fatalf("current token after password change status=%d", got)
	}
}

func TestLoginMigratesALegacyBcryptHashOnlyAfterFullSuccess(t *testing.T) {
	owner := newRotationOwner(t)
	legacy, err := bcrypt.GenerateFromPassword([]byte("owner-password-123"), 10)
	if err != nil {
		t.Fatalf("legacy hash: %v", err)
	}
	if _, err := owner.db.Exec(`UPDATE accounts SET password_hash = ?`, string(legacy)); err != nil {
		t.Fatalf("set legacy hash: %v", err)
	}
	storedHash := func() string {
		var hash string
		if err := owner.db.QueryRow(`SELECT password_hash FROM accounts`).Scan(&hash); err != nil {
			t.Fatalf("read hash: %v", err)
		}
		return hash
	}
	login := func(password, deviceSecret string) int {
		status, _ := doJSON(t, owner.handler, http.MethodPost, "/api/v1/auth/login", "", map[string]string{
			"username": "owner", "password": password, "device_id": owner.deviceID, "device_secret": deviceSecret,
		})
		return status
	}
	if got := login("owner-password-123", "wrong-device-secret"); got != http.StatusUnauthorized {
		t.Fatalf("wrong device secret login status=%d", got)
	}
	if storedHash() != string(legacy) {
		t.Fatal("hash migrated before the device secret was checked")
	}
	if got := login("owner-password-123", owner.deviceSecret); got != http.StatusOK {
		t.Fatalf("legacy login status=%d", got)
	}
	migrated := storedHash()
	if !strings.HasPrefix(migrated, "$argon2id$v=19$") {
		t.Fatalf("legacy hash not migrated: %.10s", migrated)
	}
	if got := login("owner-password-123", owner.deviceSecret); got != http.StatusOK {
		t.Fatalf("migrated login status=%d", got)
	}
	if got := login("wrong-password-123", owner.deviceSecret); got != http.StatusUnauthorized {
		t.Fatalf("wrong password after migration status=%d", got)
	}
	if storedHash() != migrated {
		t.Fatal("a current hash was rewritten")
	}
}
