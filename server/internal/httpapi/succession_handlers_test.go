package httpapi_test

import (
	"net/http"
	"testing"
)

// C4 server succession routes: asks are kept while the owner is active, the
// owner's own ask is a transfer, and bad input is refused.
func TestOwnerSuccessionRoutesAPI(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	bobToken, bobID := registerMemberWithID(t, handler, ownerToken, "succbob")
	carolToken, carolID := registerMemberWithID(t, handler, ownerToken, "succcarol")

	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]string{})
	if status != http.StatusCreated {
		t.Fatalf("create community: status=%d body=%s", status, body)
	}
	var community struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &community)
	base := "/api/v1/communities/" + community.ID
	if status, body := doJSON(t, handler, http.MethodPost, base+"/members", ownerToken, map[string]string{"account_id": bobID, "role": "admin"}); status != http.StatusOK {
		t.Fatalf("add admin: status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodPost, base+"/members", ownerToken, map[string]string{"account_id": carolID, "role": "member"}); status != http.StatusOK {
		t.Fatalf("add member: status=%d body=%s", status, body)
	}
	expect := func(label string, want int, path, token string, payload interface{}, wantStatus string) {
		t.Helper()
		got, response := doJSON(t, handler, http.MethodPost, path, token, payload)
		if got != want {
			t.Fatalf("%s: status=%d want %d body=%s", label, got, want, response)
		}
		if wantStatus != "" {
			var out struct {
				Status string `json:"status"`
			}
			decodeBody(t, response, &out)
			if out.Status != wantStatus {
				t.Fatalf("%s: body=%s want status %q", label, response, wantStatus)
			}
		}
	}
	path := base + "/owner-succession"
	expect("bad candidate", http.StatusBadRequest, path, bobToken, map[string]string{"candidate_account_id": "nope"}, "")
	expect("member asks", http.StatusForbidden, path, carolToken, map[string]string{"candidate_account_id": bobID}, "")
	expect("non-admin candidate", http.StatusForbidden, path, bobToken, map[string]string{"candidate_account_id": carolID}, "")
	// The owner is active (it just made the community): the ask is kept.
	expect("admin asks", http.StatusOK, path, bobToken, map[string]string{"candidate_account_id": bobID}, "recorded")
	// The owner's own ask hands over at once.
	expect("owner transfers", http.StatusOK, path, ownerToken, map[string]string{"candidate_account_id": bobID}, "moved")
	status, body = doJSON(t, handler, http.MethodGet, base+"/members", bobToken, nil)
	var members struct {
		Members []struct {
			AccountID string `json:"account_id"`
			Role      string `json:"role"`
		} `json:"members"`
	}
	decodeBody(t, body, &members)
	roles := map[string]string{}
	for _, m := range members.Members {
		roles[m.AccountID] = m.Role
	}
	if status != http.StatusOK || roles[bobID] != "owner" {
		t.Fatalf("members after transfer: status=%d body=%s", status, body)
	}
	// A group outside any community uses the conversation route.
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{"kind": "group", "member_account_ids": []string{carolID}})
	if status != http.StatusCreated {
		t.Fatalf("create group: status=%d body=%s", status, body)
	}
	var group struct {
		ID string `json:"id"`
	}
	decodeBody(t, body, &group)
	expect("group member claim while owner active", http.StatusOK, "/api/v1/conversations/"+group.ID+"/owner-succession", carolToken, map[string]string{"candidate_account_id": carolID}, "recorded")
	expect("stranger", http.StatusForbidden, "/api/v1/conversations/"+group.ID+"/owner-succession", bobToken, map[string]string{"candidate_account_id": bobID}, "")
}
