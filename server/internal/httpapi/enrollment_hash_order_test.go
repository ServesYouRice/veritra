package httpapi_test

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/httpapi"
)

// C-362f5a93b11d: register and owner setup hash the password only after the
// enrollment proof holds, so an anonymous caller without a reservation
// cannot spend a password-hashing slot. The policy check still comes first.
func TestEnrollmentHashesThePasswordOnlyAfterTheProof(t *testing.T) {
	calls := 0
	restore := httpapi.SetHashNewPasswordForTest(func(ctx context.Context, caller auth.Caller, password string) (string, error) {
		calls++
		return auth.HashPasswordContext(ctx, caller, password)
	})
	defer restore()

	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	calls = 0
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
	body := func() map[string]interface{} {
		return map[string]interface{}{
			"invite_code":        invite.Code,
			"username":           "mallory",
			"password":           "member-password-123",
			"device_name":        "mallory phone",
			"device_key_package": make([]byte, 64),
		}
	}

	// No reservation and no proof: refused without hashing.
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register", "", body())
	if status != http.StatusBadRequest || !jsonErrorIs(response, "invalid_enrollment") {
		t.Fatalf("register without proof status=%d body=%s", status, response)
	}
	// A weak password is still reported before the proof is looked at.
	weak := body()
	weak["password"] = "short"
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register", "", weak)
	if status != http.StatusBadRequest || !jsonErrorIs(response, "weak_password") {
		t.Fatalf("register with a weak password status=%d body=%s", status, response)
	}
	// Owner setup is gated too, and the instance is already set up, but
	// the proof check still comes before the hash.
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", map[string]interface{}{
		"username": "second-owner", "password": "owner-password-123",
		"device_name": "phone", "device_key_package": make([]byte, 64),
	})
	if status != http.StatusBadRequest || !jsonErrorIs(response, "invalid_enrollment") {
		t.Fatalf("owner setup without proof status=%d body=%s", status, response)
	}
	if calls != 0 {
		t.Fatalf("password hashed %d times for requests without a valid enrollment proof", calls)
	}

	// With a valid proof the password is hashed once and the account made.
	valid := body()
	addEnrollmentProof(valid, reserveEnrollment(t, handler, "/api/v1/register/enrollment", invite.Code))
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register", "", valid)
	if status != http.StatusCreated {
		t.Fatalf("register with proof status=%d body=%s", status, response)
	}
	if calls != 1 {
		t.Fatalf("password hashed %d times for a valid registration, want 1", calls)
	}
}

func jsonErrorIs(body []byte, code string) bool {
	var decoded struct {
		Error string `json:"error"`
	}
	return json.Unmarshal(body, &decoded) == nil && decoded.Error == code
}
