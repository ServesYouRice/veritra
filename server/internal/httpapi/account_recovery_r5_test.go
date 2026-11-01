package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// K0 R5: the forced password step after a recovery must change the
// password, so the route refuses the current one.
func TestChangePasswordRefusesTheCurrentPassword(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	if status, body := f.do(http.MethodPost, "/api/v1/auth/reauth", f.ownerToken, map[string]string{"password": "owner-password-123", "device_secret": f.ownerDeviceSecret}, nil); status != http.StatusNoContent {
		t.Fatalf("reauth: %d %s", status, body)
	}
	if status, body := f.do(http.MethodPost, "/api/v1/account/password", f.ownerToken, map[string]string{"new_password": "owner-password-123"}, nil); status != http.StatusBadRequest || !jsonErrorIs(body, "password_unchanged") {
		t.Fatalf("same password: %d %s", status, body)
	}
	if status, body := f.do(http.MethodPost, "/api/v1/account/password", f.ownerToken, map[string]string{"new_password": "owner-password-789"}, nil); status != http.StatusNoContent {
		t.Fatalf("new password: %d %s", status, body)
	}
}

// GET /account/recovery-key names the origin claims are checked against,
// and only while recovery is on.
func TestRecoveryKeyStatusNamesThePublicOrigin(t *testing.T) {
	for _, origin := range []string{recoveryTestOrigin, ""} {
		f := newRecoveryFixture(t, origin)
		status, body := f.do(http.MethodGet, "/api/v1/account/recovery-key", f.ownerToken, nil, nil)
		if status != http.StatusOK {
			t.Fatalf("status: %d %s", status, body)
		}
		var decoded map[string]interface{}
		if err := json.Unmarshal(body, &decoded); err != nil {
			t.Fatal(err)
		}
		got, present := decoded["public_origin"]
		if origin == "" {
			if present {
				t.Fatalf("recovery off still names an origin: %s", body)
			}
			continue
		}
		if got != origin {
			t.Fatalf("public_origin = %v, want %s", got, origin)
		}
	}
}
