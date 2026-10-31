package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"private-messenger/server/internal/config"
)

// An account may claim only so many key packages of one other device a day;
// past that the claim is refused with 429 and a code the app can tell from
// an exhausted device (409 key_package_unavailable).
func TestKeyPackageClaimPastTheDailyAllowanceIsRefused(t *testing.T) {
	handler, ownerToken := newLimitedHandler(t, config.Limits{KeyPackageClaimsPerTarget: 1})
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
	path := "/api/v1/conversations/" + conversation.ID + "/key-packages/claim"
	first := doRawRecorder(t, handler, http.MethodPost, path, ownerToken, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("first claim status=%d body=%s", first.Code, first.Body.String())
	}
	second := doRawRecorder(t, handler, http.MethodPost, path, ownerToken, nil)
	if second.Code != http.StatusTooManyRequests || !bytes.Contains(second.Body.Bytes(), []byte("key_package_claim_limit")) {
		t.Fatalf("second claim status=%d body=%s, want 429 key_package_claim_limit", second.Code, second.Body.String())
	}
	if second.Header().Get("Retry-After") == "" {
		t.Fatal("the refusal carries no Retry-After")
	}
}
