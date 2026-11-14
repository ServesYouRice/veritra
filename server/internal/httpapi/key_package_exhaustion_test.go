package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/mlswire/mlswiretest"
)

// uploadKeyPackages uploads count additional key packages for the calling device.
func uploadKeyPackages(t *testing.T, handler http.Handler, token string, count int) {
	t.Helper()
	packages := make([]map[string]interface{}, count)
	for i := 0; i < count; i++ {
		packages[i] = map[string]interface{}{
			"key_package": mlswiretest.KeyPackage(),
			"ciphersuite": "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
			"expires_at":  time.Now().UTC().Add(7 * 24 * time.Hour),
		}
	}
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/devices/me/key-packages", token, map[string]interface{}{
		"key_packages": packages,
	})
	if status != http.StatusCreated && status != http.StatusOK {
		t.Fatalf("upload key packages status=%d body=%s", status, response)
	}
}

// claimedPackages claims one package of each named device and returns how
// many came back; a device over its allowance or out of packages is skipped.
func claimedPackages(t *testing.T, handler http.Handler, token, conversationID string, deviceIDs ...string) int {
	t.Helper()
	recorder := claimKeyPackages(t, handler, token, conversationID, deviceIDs...)
	if recorder.Code != http.StatusOK {
		t.Fatalf("claim status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var claimed struct {
		KeyPackages []json.RawMessage `json:"key_packages"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &claimed); err != nil {
		t.Fatalf("decode claim: %v %s", err, recorder.Body.String())
	}
	return len(claimed.KeyPackages)
}

// VAL-217 (audit plan Q-005 option (b), TASK-216): an attacker repeatedly creating
// conversations and claiming key packages for a target device is capped by
// KeyPackageClaimsPerTarget (the device is skipped, as for one with no package
// left) and cannot exhaust the target's pool. A legitimate third-party account
// can still add the target to a new conversation and successfully claim a key
// package.
func TestTargetedKeyPackageExhaustionPreventedByClaimCap(t *testing.T) {
	// Cap per claimer-target pair is set to 2. Target has 5 key packages.
	handler, ownerToken := newLimitedHandler(t, config.Limits{
		KeyPackageClaimsPerTarget: 2,
	})

	targetToken, targetID := registerMemberWithID(t, handler, ownerToken, "target")
	targetDevice := firstDeviceID(t, handler, targetToken)
	// Target initially has 1 key package from registration; upload 4 more so total is 5.
	uploadKeyPackages(t, handler, targetToken, 4)

	attackerToken, _ := registerMemberWithID(t, handler, ownerToken, "attacker")
	legitimateToken, _ := registerMemberWithID(t, handler, ownerToken, "legitimate")

	// Attacker creates conversations with target and claims key packages.
	// First claim: ok.
	conv1 := createGroupWithMember(t, handler, attackerToken, targetID)
	if got := claimedPackages(t, handler, attackerToken, conv1, targetDevice); got != 1 {
		t.Fatalf("attacker claim 1 returned %d packages, want 1", got)
	}

	// Second claim: ok (reached limit of 2).
	conv2 := createGroupWithMember(t, handler, attackerToken, targetID)
	if got := claimedPackages(t, handler, attackerToken, conv2, targetDevice); got != 1 {
		t.Fatalf("attacker claim 2 returned %d packages, want 1", got)
	}

	// Third claim: the target is skipped and nothing is taken.
	conv3 := createGroupWithMember(t, handler, attackerToken, targetID)
	if got := claimedPackages(t, handler, attackerToken, conv3, targetDevice); got != 0 {
		t.Fatalf("attacker claim 3 returned %d packages, want none past the cap", got)
	}

	// Legitimate account now adds target to a new conversation and claims a key package.
	// Since the legitimate account has claimed 0 from target, and target still has 3 packages left,
	// the claim succeeds.
	legitConv := createGroupWithMember(t, handler, legitimateToken, targetID)
	if got := claimedPackages(t, handler, legitimateToken, legitConv, targetDevice); got != 1 {
		t.Fatalf("legitimate user claim returned %d packages, want 1", got)
	}
}

// Characterization of the defect before the per-target cap: without a per-target
// cap (or if the cap were higher than available packages), an attacker could drain
// all key packages via repeated non-consensual conversations until the target is
// completely exhausted (its device is then skipped), leaving a legitimate user unable
// to add the target.
func TestTargetedKeyPackageExhaustionCharacterizationDrain(t *testing.T) {
	// Set limit higher than total packages so the drain defect is observable.
	handler, ownerToken := newLimitedHandler(t, config.Limits{
		KeyPackageClaimsPerTarget: 10,
	})

	targetToken, targetID := registerMemberWithID(t, handler, ownerToken, "targetdrain")
	targetDevice := firstDeviceID(t, handler, targetToken)
	// Target has 1 from register + 1 uploaded = 2 total.
	uploadKeyPackages(t, handler, targetToken, 1)

	attackerToken, _ := registerMemberWithID(t, handler, ownerToken, "attackerdrain")
	legitimateToken, _ := registerMemberWithID(t, handler, ownerToken, "legitimatedrain")

	// Attacker claims package 1
	c1 := createGroupWithMember(t, handler, attackerToken, targetID)
	if got := claimedPackages(t, handler, attackerToken, c1, targetDevice); got != 1 {
		t.Fatalf("claim 1 returned %d packages, want 1", got)
	}

	// Attacker claims package 2 (pool now empty)
	c2 := createGroupWithMember(t, handler, attackerToken, targetID)
	if got := claimedPackages(t, handler, attackerToken, c2, targetDevice); got != 1 {
		t.Fatalf("claim 2 returned %d packages, want 1", got)
	}

	// Target is now exhausted: further claims skip it.
	c3 := createGroupWithMember(t, handler, legitimateToken, targetID)
	if got := claimedPackages(t, handler, legitimateToken, c3, targetDevice); got != 0 {
		t.Fatalf("claim 3 returned %d packages, want none from an exhausted device", got)
	}
}

func createGroupWithMember(t *testing.T, handler http.Handler, creatorToken, memberID string) string {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", creatorToken,
		map[string]interface{}{"kind": "group", "member_account_ids": []string{memberID}})
	if status != http.StatusCreated {
		t.Fatalf("create conversation status=%d body=%s", status, response)
	}
	var conv struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &conv); err != nil {
		t.Fatal(err)
	}
	return conv.ID
}
