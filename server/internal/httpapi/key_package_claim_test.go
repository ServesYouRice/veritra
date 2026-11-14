package httpapi_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"private-messenger/server/internal/config"
)

// A key-package claim consumes other devices' one-time packages, so it is
// charged to the account's write budget like the other MLS write routes
// (VAL-230). Past the budget the answer is 429 with Retry-After, not another
// claim.
func TestKeyPackageClaimChargesWriteBudget(t *testing.T) {
	handler, ownerToken := newLimitedHandler(t, config.Limits{ConversationMembers: 9, DeliveriesPerMinute: 30})
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "member")
	memberDevice := firstDeviceID(t, handler, memberToken)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken,
		map[string]interface{}{"kind": "group", "member_account_ids": []string{memberID}})
	if status != http.StatusCreated {
		t.Fatalf("create group status=%d body=%s", status, response)
	}
	var conversation struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &conversation); err != nil {
		t.Fatal(err)
	}
	var refused *int
	claims := 0
	for i := 0; i < 60; i++ {
		recorder := claimKeyPackages(t, handler, ownerToken, conversation.ID, memberDevice)
		claims++
		if recorder.Code == http.StatusTooManyRequests {
			code := recorder.Code
			refused = &code
			if seconds, err := strconv.Atoi(recorder.Header().Get("Retry-After")); err != nil || seconds < 1 {
				t.Fatalf("Retry-After=%q", recorder.Header().Get("Retry-After"))
			}
			break
		}
	}
	if refused == nil {
		t.Fatalf("%d claims in a minute were never refused by the write budget", claims)
	}
	if claims < 2 {
		t.Fatalf("the budget refused the first claim")
	}
}

// claimKeyPackages claims one key package for each named device.
func claimKeyPackages(t *testing.T, handler http.Handler, token, conversationID string, deviceIDs ...string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]interface{}{"device_ids": deviceIDs})
	if err != nil {
		t.Fatal(err)
	}
	return doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/key-packages/claim", token, body)
}
