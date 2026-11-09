package httpapi_test

import (
	"bytes"
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

// VAL-217 (audit plan Q-005 option (b), TASK-216): an attacker repeatedly creating
// conversations and claiming key packages for a target device is capped by
// KeyPackageClaimsPerTarget (HTTP 429 key_package_claim_limit) and cannot exhaust
// the target's pool. A legitimate third-party account can still add the target
// to a new conversation and successfully claim a key package.
func TestTargetedKeyPackageExhaustionPreventedByClaimCap(t *testing.T) {
	// Cap per claimer-target pair is set to 2. Target has 5 key packages.
	handler, ownerToken := newLimitedHandler(t, config.Limits{
		KeyPackageClaimsPerTarget: 2,
	})

	targetToken, targetID := registerMemberWithID(t, handler, ownerToken, "target")
	// Target initially has 1 key package from registration; upload 4 more so total is 5.
	uploadKeyPackages(t, handler, targetToken, 4)

	attackerToken, _ := registerMemberWithID(t, handler, ownerToken, "attacker")
	legitimateToken, _ := registerMemberWithID(t, handler, ownerToken, "legitimate")

	// Attacker creates conversations with target and claims key packages.
	// First claim: ok.
	conv1 := createGroupWithMember(t, handler, attackerToken, targetID)
	claim1 := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+conv1+"/key-packages/claim", attackerToken, nil)
	if claim1.Code != http.StatusOK {
		t.Fatalf("attacker claim 1 status=%d body=%s", claim1.Code, claim1.Body.String())
	}

	// Second claim: ok (reached limit of 2).
	conv2 := createGroupWithMember(t, handler, attackerToken, targetID)
	claim2 := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+conv2+"/key-packages/claim", attackerToken, nil)
	if claim2.Code != http.StatusOK {
		t.Fatalf("attacker claim 2 status=%d body=%s", claim2.Code, claim2.Body.String())
	}

	// Third claim: refused with 429 key_package_claim_limit.
	conv3 := createGroupWithMember(t, handler, attackerToken, targetID)
	claim3 := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+conv3+"/key-packages/claim", attackerToken, nil)
	if claim3.Code != http.StatusTooManyRequests || !bytes.Contains(claim3.Body.Bytes(), []byte("key_package_claim_limit")) {
		t.Fatalf("attacker claim 3 status=%d body=%s, want 429 key_package_claim_limit", claim3.Code, claim3.Body.String())
	}

	// Legitimate account now adds target to a new conversation and claims a key package.
	// Since the legitimate account has claimed 0 from target, and target still has 3 packages left,
	// the claim succeeds.
	legitConv := createGroupWithMember(t, handler, legitimateToken, targetID)
	legitClaim := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+legitConv+"/key-packages/claim", legitimateToken, nil)
	if legitClaim.Code != http.StatusOK {
		t.Fatalf("legitimate user claim status=%d body=%s, want 200 OK", legitClaim.Code, legitClaim.Body.String())
	}
	var claimed struct {
		KeyPackages []json.RawMessage `json:"key_packages"`
	}
	if err := json.Unmarshal(legitClaim.Body.Bytes(), &claimed); err != nil || len(claimed.KeyPackages) == 0 {
		t.Fatalf("legitimate claim returned no packages: %v %s", err, legitClaim.Body.String())
	}
}

// Characterization of the defect before the per-target cap: without a per-target
// cap (or if the cap were higher than available packages), an attacker could drain
// all key packages via repeated non-consensual conversations until the target is
// completely exhausted (409 key_package_unavailable), leaving a legitimate user unable
// to add the target.
func TestTargetedKeyPackageExhaustionCharacterizationDrain(t *testing.T) {
	// Set limit higher than total packages so the drain defect is observable.
	handler, ownerToken := newLimitedHandler(t, config.Limits{
		KeyPackageClaimsPerTarget: 10,
	})

	targetToken, targetID := registerMemberWithID(t, handler, ownerToken, "targetdrain")
	// Target has 1 from register + 1 uploaded = 2 total.
	uploadKeyPackages(t, handler, targetToken, 1)

	attackerToken, _ := registerMemberWithID(t, handler, ownerToken, "attackerdrain")
	legitimateToken, _ := registerMemberWithID(t, handler, ownerToken, "legitimatedrain")

	// Attacker claims package 1
	c1 := createGroupWithMember(t, handler, attackerToken, targetID)
	res1 := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+c1+"/key-packages/claim", attackerToken, nil)
	if res1.Code != http.StatusOK {
		t.Fatalf("claim 1 status=%d body=%s", res1.Code, res1.Body.String())
	}

	// Attacker claims package 2 (pool now empty)
	c2 := createGroupWithMember(t, handler, attackerToken, targetID)
	res2 := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+c2+"/key-packages/claim", attackerToken, nil)
	if res2.Code != http.StatusOK {
		t.Fatalf("claim 2 status=%d body=%s", res2.Code, res2.Body.String())
	}

	// Target is now exhausted: further claims fail with 409 key_package_unavailable.
	c3 := createGroupWithMember(t, handler, legitimateToken, targetID)
	res3 := doRawRecorder(t, handler, http.MethodPost, "/api/v1/conversations/"+c3+"/key-packages/claim", legitimateToken, nil)
	if res3.Code != http.StatusConflict || !bytes.Contains(res3.Body.Bytes(), []byte("key_package_unavailable")) {
		t.Fatalf("claim 3 status=%d body=%s, want 409 key_package_unavailable", res3.Code, res3.Body.String())
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
