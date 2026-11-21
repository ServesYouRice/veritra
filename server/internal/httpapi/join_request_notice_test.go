package httpapi_test

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

// Owner decision 2026-11-21: a new join request tells the target's owners and
// admins with a stored account event that carries nothing, and the
// provider's fixed generic wake. Members and the requester are not told, and
// asking again tells no one twice.
func TestJoinRequestNoticesAdminsWithAContentFreeWake(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	rec := &wakeRecorder{}
	f.app.Push = rec
	f.handler = f.app.Handler()
	t.Cleanup(func() { f.app.WaitPushWakes(time.Now().Add(5 * time.Second)) })

	adminToken, adminID := registerMemberWithID(t, f.handler, f.ownerToken, "jradmin")
	memberToken, memberID := registerMemberWithID(t, f.handler, f.ownerToken, "jrmember")
	requesterToken, requesterID := registerMemberWithID(t, f.handler, f.ownerToken, "jrrequester")

	status, body := f.do(http.MethodPost, "/api/v1/communities", f.ownerToken, map[string]string{}, nil)
	if status != http.StatusCreated {
		t.Fatalf("create community: %d %s", status, body)
	}
	var community struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &community)
	base := "/api/v1/communities/" + community.ID
	for id, role := range map[string]string{adminID: "admin", memberID: "member"} {
		if status, body := f.do(http.MethodPost, base+"/members", f.ownerToken, map[string]string{"account_id": id, "role": role}, nil); status != http.StatusOK {
			t.Fatalf("add %s: %d %s", role, status, body)
		}
	}
	endpoints := map[string]string{}
	for i, id := range []string{f.ownerAccountID, adminID, memberID, requesterID} {
		endpoint := fmt.Sprintf("fcm-token-jr-%d-0123456789-0123456789", i)
		endpoints[endpoint] = id
		f.exec(`INSERT INTO push_subscriptions(id, account_id, device_id, provider, endpoint, public_key, auth_secret, created_at, notification_mode)
			VALUES(?, ?, NULL, 'fcm', ?, '', '', ?, 'local_decrypt_v1')`, fmt.Sprintf("push_jr_%d", i), id, endpoint, recoveryTestTime(time.Now()))
	}
	if status, body := f.do(http.MethodPost, base+"/invites", f.ownerToken, inviteBody(t, f.handler, f.ownerToken, map[string]interface{}{"max_uses": 5}), nil); status != http.StatusCreated {
		t.Fatalf("create invite: %d %s", status, body)
	}
	status, body = f.do(http.MethodPost, "/api/v1/membership-invites/requests", requesterToken, map[string]string{"locator": testInviteLocator}, nil)
	if status != http.StatusCreated {
		t.Fatalf("request: %d %s", status, body)
	}
	var request struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &request)

	sent := rec.waitFor(t, 2)
	woken := map[string]bool{}
	for _, n := range sent {
		woken[endpoints[n.Endpoint]] = true
		// Only the routing target is set: the fixed generic wake.
		for _, leaked := range []string{request.ID, requesterID, "jrrequester", community.ID} {
			if strings.Contains(fmt.Sprintf("%+v", n), leaked) {
				t.Fatalf("wake leaks %q: %+v", leaked, n)
			}
		}
	}
	if !woken[f.ownerAccountID] || !woken[adminID] || len(woken) != 2 {
		t.Fatalf("woken = %v", woken)
	}
	if got := f.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.join_request' AND payload_json = '{}'`); got != 2 {
		t.Fatalf("notice events = %d", got)
	}
	if got := f.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.join_request' AND account_id IN (?, ?)`, memberID, requesterID); got != 0 {
		t.Fatalf("notice events for a member or the requester = %d", got)
	}

	// Asking again returns the same request and tells no one.
	if status, body := f.do(http.MethodPost, "/api/v1/membership-invites/requests", requesterToken, map[string]string{"locator": testInviteLocator}, nil); status != http.StatusOK {
		t.Fatalf("repeat: %d %s", status, body)
	}
	rec.waitFor(t, 2)

	// While invitations are paused the admin still sees the request, is told
	// the pause, cannot approve and can decline (owner decision 2026-11-21).
	if status, body := f.do(http.MethodPut, base+"/invites-pause", adminToken, map[string]int{"seconds": 600}, nil); status != http.StatusOK {
		t.Fatalf("pause: %d %s", status, body)
	}
	status, body = f.do(http.MethodGet, base+"/join-requests", adminToken, nil, nil)
	var listed struct {
		Requests []struct {
			ID string `json:"id"`
		} `json:"requests"`
		InvitesPausedUntil *string `json:"invites_paused_until"`
	}
	decodeBody(t, body, &listed)
	if status != http.StatusOK || len(listed.Requests) != 1 || listed.InvitesPausedUntil == nil {
		t.Fatalf("list while paused: %d %s", status, body)
	}
	if status, body := f.do(http.MethodPost, "/api/v1/join-requests/"+request.ID+"/approve", adminToken, nil, nil); status == http.StatusOK {
		t.Fatalf("approve while paused: %d %s", status, body)
	}
	if status, body := f.do(http.MethodPost, "/api/v1/join-requests/"+request.ID+"/reject", adminToken, nil, nil); status != http.StatusOK {
		t.Fatalf("decline while paused: %d %s", status, body)
	}
	status, body = f.do(http.MethodGet, base+"/join-requests", memberToken, nil, nil)
	if status == http.StatusOK {
		t.Fatalf("member lists requests: %s", body)
	}

	// Declined, or cancelling, and filing again is a new request each time,
	// but no admin is woken again inside the quiet window: an invitation
	// link must not become a way to push the admins at will.
	if status, body := f.do(http.MethodPut, base+"/invites-pause", adminToken, map[string]int{"seconds": 0}, nil); status != http.StatusOK {
		t.Fatalf("resume: %d %s", status, body)
	}
	for i := 0; i < 4; i++ {
		status, body := f.do(http.MethodPost, "/api/v1/membership-invites/requests", requesterToken, map[string]string{"locator": testInviteLocator}, nil)
		if status != http.StatusCreated {
			t.Fatalf("refile %d: %d %s", i, status, body)
		}
		var refiled struct {
			ID string `json:"id"`
		}
		decodeBody(t, body, &refiled)
		if status, body := f.do(http.MethodDelete, "/api/v1/join-requests/"+refiled.ID, requesterToken, nil, nil); status != http.StatusOK {
			t.Fatalf("cancel %d: %d %s", i, status, body)
		}
	}
	rec.waitFor(t, 2)
	if got := f.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.join_request'`); got != 2 {
		t.Fatalf("notice events after refiling = %d", got)
	}
}

// Owner decision 2026-11-21: an admin sees and lifts the timeout of someone
// who left; a moderator cannot.
func TestDepartedTimeoutRoutesAPI(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	modToken, modID := registerMemberWithID(t, handler, ownerToken, "dtmod")
	bobToken, bobID := registerMemberWithID(t, handler, ownerToken, "dtbob")
	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]string{})
	if status != http.StatusCreated {
		t.Fatalf("create community: %d %s", status, body)
	}
	var community struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &community)
	base := "/api/v1/communities/" + community.ID
	for id, role := range map[string]string{modID: "moderator", bobID: "member"} {
		if status, body := doJSON(t, handler, http.MethodPost, base+"/members", ownerToken, map[string]string{"account_id": id, "role": role}); status != http.StatusOK {
			t.Fatalf("add: %d %s", status, body)
		}
	}
	if status, body := doJSON(t, handler, http.MethodPut, base+"/members/"+bobID+"/timeout", ownerToken, map[string]int{"seconds": 600}); status != http.StatusOK {
		t.Fatalf("timeout: %d %s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodDelete, base+"/members/me", bobToken, nil); status != http.StatusOK {
		t.Fatalf("leave: %d %s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodGet, base+"/timeouts", ownerToken, nil)
	if status != http.StatusOK || !strings.Contains(string(body), bobID) || !strings.Contains(string(body), `"username":"dtbob"`) {
		t.Fatalf("list: %d %s", status, body)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, base+"/timeouts", bobToken, nil); status != http.StatusForbidden {
		t.Fatalf("non-member lists: %d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodPut, base+"/members/"+bobID+"/timeout", modToken, map[string]int{"seconds": 0}); status != http.StatusForbidden {
		t.Fatalf("moderator lifts: %d", status)
	}
	if status, body := doJSON(t, handler, http.MethodPut, base+"/members/"+bobID+"/timeout", ownerToken, map[string]int{"seconds": 0}); status != http.StatusOK {
		t.Fatalf("owner lifts: %d %s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodGet, base+"/timeouts", ownerToken, nil)
	if status != http.StatusOK || strings.Contains(string(body), bobID) {
		t.Fatalf("list after lift: %d %s", status, body)
	}
	if status, _ := doJSON(t, handler, http.MethodPut, base+"/members/"+bobID+"/timeout", ownerToken, map[string]int{"seconds": 0}); status != http.StatusNotFound {
		t.Fatalf("lift again: %d", status)
	}
}
