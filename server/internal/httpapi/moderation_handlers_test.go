package httpapi_test

import (
	"net/http"
	"testing"
)

func TestModerationRoutesAPI(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	bobToken, bobID := registerMemberWithID(t, handler, ownerToken, "modbob")
	carolToken, carolID := registerMemberWithID(t, handler, ownerToken, "modcarol")

	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]string{"name": "Club"})
	if status != http.StatusCreated {
		t.Fatalf("create community: status=%d body=%s", status, body)
	}
	var community struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &community)
	base := "/api/v1/communities/" + community.ID
	if status, body := doJSON(t, handler, http.MethodPost, base+"/channels", ownerToken, map[string]string{"name": "general"}); status != http.StatusCreated {
		t.Fatalf("create channel: status=%d body=%s", status, body)
	}
	for _, id := range []string{bobID, carolID} {
		if status, body := doJSON(t, handler, http.MethodPost, base+"/members", ownerToken, map[string]string{"account_id": id, "role": "member"}); status != http.StatusOK {
			t.Fatalf("add member: status=%d body=%s", status, body)
		}
	}
	status, body = doJSON(t, handler, http.MethodGet, base+"/channels", ownerToken, nil)
	var channels struct {
		Channels []struct {
			ID string `json:"id"`
		} `json:"channels"`
	}
	decodeBody(t, body, &channels)
	if status != http.StatusOK || len(channels.Channels) != 1 {
		t.Fatalf("channels: status=%d body=%s", status, body)
	}
	channel := channels.Channels[0].ID

	expect := func(label string, want int, method, path, token string, payload interface{}) []byte {
		t.Helper()
		got, response := doJSON(t, handler, method, path, token, payload)
		if got != want {
			t.Fatalf("%s: status=%d want %d body=%s", label, got, want, response)
		}
		return response
	}
	// A member may not moderate anything.
	expect("member kicks", http.StatusForbidden, http.MethodPost, base+"/members/"+carolID+"/kick", bobToken, nil)
	expect("member bans", http.StatusForbidden, http.MethodPost, base+"/bans", bobToken, map[string]string{"account_id": carolID})
	expect("member timeouts", http.StatusForbidden, http.MethodPut, base+"/members/"+carolID+"/timeout", bobToken, map[string]int{"seconds": 60})
	expect("member slow mode", http.StatusForbidden, http.MethodPut, base+"/channels/"+channel+"/slow-mode", bobToken, map[string]int{"seconds": 60})
	expect("member pauses", http.StatusForbidden, http.MethodPut, base+"/invites-pause", bobToken, map[string]int{"seconds": 60})
	expect("member reads log", http.StatusForbidden, http.MethodGet, base+"/moderation-events", bobToken, nil)
	// Bad input.
	expect("bad account", http.StatusBadRequest, http.MethodPost, base+"/bans", ownerToken, map[string]string{"account_id": "nope"})
	expect("negative seconds", http.StatusBadRequest, http.MethodPut, base+"/invites-pause", ownerToken, map[string]int{"seconds": -1})
	expect("too long a timeout", http.StatusBadRequest, http.MethodPut, base+"/members/"+carolID+"/timeout", ownerToken, map[string]int{"seconds": 29 * 24 * 3600})
	// The owner moderates.
	expect("timeout", http.StatusOK, http.MethodPut, base+"/members/"+carolID+"/timeout", ownerToken, map[string]int{"seconds": 600})
	expect("slow mode", http.StatusOK, http.MethodPut, base+"/channels/"+channel+"/slow-mode", ownerToken, map[string]int{"seconds": 30})
	expect("pause", http.StatusOK, http.MethodPut, base+"/invites-pause", ownerToken, map[string]int{"seconds": 600})
	expect("kick", http.StatusOK, http.MethodPost, base+"/members/"+bobID+"/kick", ownerToken, nil)
	expect("ban", http.StatusOK, http.MethodPost, base+"/bans", ownerToken, map[string]string{"account_id": carolID})
	expect("a banned account cannot be re-added", http.StatusForbidden, http.MethodPost, base+"/members", ownerToken, map[string]string{"account_id": carolID, "role": "member"})
	expect("banned account sees nothing", http.StatusForbidden, http.MethodGet, base+"/members", carolToken, nil)
	body = expect("bans", http.StatusOK, http.MethodGet, base+"/bans", ownerToken, nil)
	var bans struct {
		Bans []struct {
			AccountID string `json:"account_id"`
		} `json:"bans"`
	}
	decodeBody(t, body, &bans)
	if len(bans.Bans) != 1 || bans.Bans[0].AccountID != carolID {
		t.Fatalf("bans = %s", body)
	}
	expect("unban", http.StatusOK, http.MethodDelete, base+"/bans/"+carolID, ownerToken, nil)
	expect("unban twice", http.StatusNotFound, http.MethodDelete, base+"/bans/"+carolID, ownerToken, nil)
	body = expect("log", http.StatusOK, http.MethodGet, base+"/moderation-events", ownerToken, nil)
	var log struct {
		Events []struct {
			Action string `json:"action"`
		} `json:"events"`
	}
	decodeBody(t, body, &log)
	seen := map[string]bool{}
	for _, e := range log.Events {
		seen[e.Action] = true
	}
	for _, action := range []string{"timeout", "slow_mode", "invites_paused", "kick", "ban", "unban"} {
		if !seen[action] {
			t.Errorf("audit log lacks %q: %s", action, body)
		}
	}
}
