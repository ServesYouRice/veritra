package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// C-1193b73013e5: a revoked invite must be refused for being revoked. The
// request carries a valid enrollment proof (reserved while the invite was
// live) and a well-formed key package, so the only thing wrong with it is
// the invite; the refusal must say invalid_invite.
func TestRegisterWithRevokedInviteIsRefusedForTheInvite(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/invites", ownerToken, map[string]interface{}{"max_uses": 5})
	if status != http.StatusCreated {
		t.Fatalf("create invite status=%d body=%s", status, response)
	}
	var invite struct {
		ID   string `json:"id"`
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response, &invite); err != nil || invite.ID == "" || invite.Code == "" {
		t.Fatalf("decode invite %s: %v", response, err)
	}
	body := func(username string) map[string]interface{} {
		return map[string]interface{}{
			"invite_code":        invite.Code,
			"username":           username,
			"password":           "member-password-123",
			"device_name":        username + " phone",
			"device_key_package": make([]byte, 64),
		}
	}
	// Reserved while the invite is live, used after it is revoked.
	early := reserveEnrollment(t, handler, "/api/v1/register/enrollment", invite.Code)

	status, response = doJSON(t, handler, http.MethodDelete, "/api/v1/invites/"+invite.ID, ownerToken, nil)
	if status != http.StatusNoContent {
		t.Fatalf("revoke invite status=%d body=%s", status, response)
	}

	revoked := body("revokedinvite")
	addEnrollmentProof(revoked, early)
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register", "", revoked)
	if status != http.StatusBadRequest || !jsonErrorIs(response, "invalid_invite") {
		t.Fatalf("revoked invite registration status=%d body=%s, want 400 invalid_invite", status, response)
	}
	// A new reservation for the revoked invite is refused too.
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register/enrollment", "", map[string]interface{}{"invite_code": invite.Code})
	if status != http.StatusBadRequest || !jsonErrorIs(response, "invalid_invite") {
		t.Fatalf("reservation for a revoked invite status=%d body=%s, want 400 invalid_invite", status, response)
	}
}
