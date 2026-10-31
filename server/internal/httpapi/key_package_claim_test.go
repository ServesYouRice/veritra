package httpapi_test

import (
	"encoding/json"
	"net/http"
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
	_, memberID := registerMemberWithID(t, handler, ownerToken, "member")
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
		recorder := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+conversation.ID+"/key-packages/claim", ownerToken, nil)
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
