package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"

	"private-messenger/server/internal/config"
)

// An account may claim only so many key packages of one other device a day;
// past that the device is skipped, as one with no package left is, and the
// device keeps its remaining packages.
func TestKeyPackageClaimPastTheDailyAllowanceTakesNothing(t *testing.T) {
	handler, ownerToken := newLimitedHandler(t, config.Limits{KeyPackageClaimsPerTarget: 1})
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "member")
	memberDevice := firstDeviceID(t, handler, memberToken)
	uploadKeyPackages(t, handler, memberToken, 3)
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
	claimed := func() int {
		t.Helper()
		recorder := claimKeyPackages(t, handler, ownerToken, conversation.ID, memberDevice)
		if recorder.Code != http.StatusOK {
			t.Fatalf("claim status=%d body=%s", recorder.Code, recorder.Body.String())
		}
		var body struct {
			KeyPackages []json.RawMessage `json:"key_packages"`
		}
		if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		return len(body.KeyPackages)
	}
	if got := claimed(); got != 1 {
		t.Fatalf("first claim returned %d packages, want 1", got)
	}
	if got := claimed(); got != 0 {
		t.Fatalf("claim past the allowance returned %d packages, want none", got)
	}
}
