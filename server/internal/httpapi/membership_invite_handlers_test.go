package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

const testInviteLocator = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func decodeBody(t *testing.T, body []byte, dest interface{}) {
	t.Helper()
	if err := json.Unmarshal(body, dest); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
}

const testBindingTag = "abababababababababababababababababababababababababababababababab"

// inviteBody is a create-invitation body for the session behind token: the
// session's device key and a stand-in binding tag (only the app can compute
// the real one, from the link secret).
func inviteBody(t *testing.T, handler http.Handler, token string, extra map[string]interface{}) map[string]interface{} {
	t.Helper()
	status, body := doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", token, nil)
	if status != http.StatusOK {
		t.Fatalf("list devices: status=%d body=%s", status, body)
	}
	var devices struct {
		Devices []struct {
			SigningKey []byte `json:"signing_key"`
		} `json:"devices"`
	}
	decodeBody(t, body, &devices)
	if len(devices.Devices) == 0 || len(devices.Devices[0].SigningKey) != 32 {
		t.Fatalf("devices = %s", body)
	}
	request := map[string]interface{}{"locator": testInviteLocator, "signing_key": devices.Devices[0].SigningKey, "binding_tag": testBindingTag}
	for key, value := range extra {
		request[key] = value
	}
	return request
}

func TestGroupInviteJoinRequestFlowAPI(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	groupID := createConversation(t, handler, ownerToken)
	aliceToken, aliceID := registerMemberWithID(t, handler, ownerToken, "invitealice")
	outsiderToken := registerMember(t, handler, ownerToken, "inviteoutsider")

	// Only an admin of the group may invite; an outsider is refused.
	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+groupID+"/invites", outsiderToken, inviteBody(t, handler, outsiderToken, map[string]interface{}{"max_uses": 2}))
	if status != http.StatusForbidden {
		t.Fatalf("outsider creates invite: status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+groupID+"/invites", ownerToken, inviteBody(t, handler, ownerToken, map[string]interface{}{"locator": "bad", "max_uses": 2}))
	if status != http.StatusBadRequest {
		t.Fatalf("bad locator: status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+groupID+"/invites", ownerToken, inviteBody(t, handler, ownerToken, map[string]interface{}{"max_uses": 2}))
	if status != http.StatusCreated {
		t.Fatalf("create invite: status=%d body=%s", status, body)
	}
	var invite struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &invite)
	// The response and the list never hold the locator.
	if bytes.Contains(body, []byte(testInviteLocator)) {
		t.Fatalf("invite response echoes the locator: %s", body)
	}
	status, body = doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+groupID+"/invites", ownerToken, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(invite.ID)) || bytes.Contains(body, []byte(testInviteLocator)) {
		t.Fatalf("list invites: status=%d body=%s", status, body)
	}

	// Preview, then request. Nothing is granted.
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/preview", aliceToken, map[string]string{"locator": testInviteLocator})
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"target_kind":"group"`)) {
		t.Fatalf("preview: status=%d body=%s", status, body)
	}
	// The preview carries the binding (D90) for the joiner to check.
	var preview struct {
		Binding struct {
			TargetID          string `json:"target_id"`
			InviterAccountID  string `json:"inviter_account_id"`
			InviterDeviceID   string `json:"inviter_device_id"`
			InviterSigningKey []byte `json:"inviter_signing_key"`
			Tag               string `json:"tag"`
		} `json:"binding"`
	}
	decodeBody(t, body, &preview)
	if preview.Binding.TargetID != groupID || preview.Binding.InviterAccountID == "" || preview.Binding.InviterDeviceID == "" ||
		len(preview.Binding.InviterSigningKey) != 32 || preview.Binding.Tag != testBindingTag {
		t.Fatalf("preview binding = %+v", preview.Binding)
	}
	for _, mutate := range []map[string]interface{}{
		{"binding_tag": "not-a-tag"},
		{"binding_tag": nil},
		{"signing_key": nil},
		{"signing_key": make([]byte, 32)},
	} {
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+groupID+"/invites", ownerToken, inviteBody(t, handler, ownerToken, mutate)); status != http.StatusBadRequest {
			t.Fatalf("create invite with %v: status=%d body=%s", mutate, status, body)
		}
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/preview", aliceToken, map[string]string{"locator": strings.Repeat("f", 64)})
	if status != http.StatusNotFound {
		t.Fatalf("preview of an unknown link: status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/requests", aliceToken, map[string]string{"locator": testInviteLocator})
	if status != http.StatusCreated || !bytes.Contains(body, []byte(`"binding":{`)) || !bytes.Contains(body, []byte(`"tag":"`+testBindingTag+`"`)) {
		t.Fatalf("request: status=%d body=%s", status, body)
	}
	var request struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	decodeBody(t, body, &request)
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/requests", aliceToken, map[string]string{"locator": testInviteLocator})
	if status != http.StatusOK {
		t.Fatalf("repeat request: status=%d body=%s", status, body)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+groupID+"/members", aliceToken, nil); status != http.StatusForbidden {
		t.Fatalf("requester reads the roster: status=%d", status)
	}

	// Admin list shows the username; the requester and outsiders cannot decide or list.
	status, body = doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+groupID+"/join-requests", ownerToken, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"username":"invitealice"`)) || !bytes.Contains(body, []byte(aliceID)) {
		t.Fatalf("list requests: status=%d body=%s", status, body)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+groupID+"/join-requests", aliceToken, nil); status != http.StatusForbidden {
		t.Fatalf("requester lists requests: status=%d", status)
	}
	for _, token := range []string{aliceToken, outsiderToken} {
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/join-requests/"+request.ID+"/approve", token, nil); status != http.StatusNotFound {
			t.Fatalf("unauthorized approve: status=%d body=%s", status, body)
		}
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/join-requests/"+request.ID+"/approve", ownerToken, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"status":"approved"`)) || !bytes.Contains(body, []byte(`"mls_coordination":"pending"`)) {
		t.Fatalf("approve: status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+groupID+"/members", aliceToken, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"username":"invitealice"`)) {
		t.Fatalf("roster after approval: status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/join-requests/"+request.ID+"/reject", ownerToken, nil); status != http.StatusConflict || !bytes.Contains(body, []byte("join_request_resolved")) {
		t.Fatalf("reject after approve: status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/requests", aliceToken, map[string]string{"locator": testInviteLocator}); status != http.StatusConflict || !bytes.Contains(body, []byte("already_member")) {
		t.Fatalf("member requests again: status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodGet, "/api/v1/join-requests", aliceToken, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"status":"approved"`)) {
		t.Fatalf("own requests: status=%d body=%s", status, body)
	}

	// Revoking ends the link.
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/membership-invites/"+invite.ID, aliceToken, nil); status != http.StatusNotFound {
		t.Fatalf("member revokes: status=%d", status)
	}
	if status, body := doJSON(t, handler, http.MethodDelete, "/api/v1/membership-invites/"+invite.ID, ownerToken, nil); status != http.StatusOK {
		t.Fatalf("revoke: status=%d body=%s", status, body)
	}
	if status, _ := doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/preview", outsiderToken, map[string]string{"locator": testInviteLocator}); status != http.StatusNotFound {
		t.Fatalf("preview after revoke: status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/requests", outsiderToken, map[string]string{"locator": testInviteLocator}); status != http.StatusNotFound {
		t.Fatalf("request after revoke: status=%d", status)
	}
}

func TestCommunityInviteAndMemberRemovalAPI(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	bobToken := registerMember(t, handler, ownerToken, "invitebob")
	carolToken, carolID := registerMemberWithID(t, handler, ownerToken, "invitecarol")

	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]string{"name": "Club"})
	if status != http.StatusCreated {
		t.Fatalf("create community: status=%d body=%s", status, body)
	}
	var community struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &community)
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]string{"name": "general"}); status != http.StatusCreated {
		t.Fatalf("create channel: status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/invites", ownerToken, inviteBody(t, handler, ownerToken, map[string]interface{}{"max_uses": 5, "expires_in_seconds": 3600})); status != http.StatusCreated {
		t.Fatalf("create community invite: status=%d body=%s", status, body)
	}
	for _, token := range []string{bobToken, carolToken} {
		status, body := doJSON(t, handler, http.MethodPost, "/api/v1/membership-invites/requests", token, map[string]string{"locator": testInviteLocator})
		if status != http.StatusCreated {
			t.Fatalf("request: status=%d body=%s", status, body)
		}
		var request struct {
			ID string `json:"id"`
		}
		decodeBody(t, body, &request)
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/join-requests/"+request.ID+"/approve", ownerToken, nil); status != http.StatusOK {
			t.Fatalf("approve: status=%d body=%s", status, body)
		}
	}
	// The member list carries usernames and is for members only.
	status, body = doJSON(t, handler, http.MethodGet, "/api/v1/communities/"+community.ID+"/members", bobToken, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"username":"invitecarol"`)) || !bytes.Contains(body, []byte(`"username":"invitebob"`)) {
		t.Fatalf("community members: status=%d body=%s", status, body)
	}

	// A member cannot remove another; an owner can; a member can leave; the last owner cannot.
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/communities/"+community.ID+"/members/"+carolID, bobToken, nil); status != http.StatusForbidden {
		t.Fatalf("member removes member: status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/communities/"+community.ID+"/members/not-an-id", ownerToken, nil); status != http.StatusBadRequest {
		t.Fatalf("bad account id: status=%d", status)
	}
	status, body = doJSON(t, handler, http.MethodDelete, "/api/v1/communities/"+community.ID+"/members/"+carolID, ownerToken, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"mls_coordination":"pending"`)) || !bytes.Contains(body, []byte(`"channels":[{`)) {
		t.Fatalf("owner removes member: status=%d body=%s", status, body)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/communities/"+community.ID+"/members", carolToken, nil); status != http.StatusForbidden {
		t.Fatalf("removed member lists members: status=%d", status)
	}
	if status, body := doJSON(t, handler, http.MethodDelete, "/api/v1/communities/"+community.ID+"/members/me", bobToken, nil); status != http.StatusOK {
		t.Fatalf("member leaves: status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodDelete, "/api/v1/communities/"+community.ID+"/members/me", ownerToken, nil)
	if status != http.StatusConflict || !bytes.Contains(body, []byte("last_owner_required")) {
		t.Fatalf("last owner leaves: status=%d body=%s", status, body)
	}
}

func TestMembershipInviteRoutesRequireAuth(t *testing.T) {
	handler, _, _ := newTestHandlerWithOwnerDevice(t)
	for _, route := range []struct{ method, path string }{
		{http.MethodPost, "/api/v1/membership-invites/preview"},
		{http.MethodPost, "/api/v1/membership-invites/requests"},
		{http.MethodGet, "/api/v1/join-requests"},
		{http.MethodPost, "/api/v1/join-requests/jreq_x/approve"},
		{http.MethodGet, "/api/v1/communities/comm_x/join-requests"},
		{http.MethodDelete, "/api/v1/communities/comm_x/members/me"},
	} {
		if status, body := doJSON(t, handler, route.method, route.path, "", map[string]string{"locator": testInviteLocator}); status != http.StatusUnauthorized {
			t.Fatalf("%s %s without a token: status=%d body=%s", route.method, route.path, status, body)
		}
	}
}
