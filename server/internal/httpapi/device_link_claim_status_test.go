package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// claim-status consumes the approved link and creates the session in one
// transaction, and answers from that transaction. A later, separate read must
// not be able to turn a consumed link into an error that discards the session
// token (VAL-227). The trigger makes any read of the consumed row after the
// commit come back empty, as a transient storage failure would.
func TestDeviceLinkClaimStatusAnswersFromTheConsumingTransaction(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	db := openSessionTestDB(t, dbPath)

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/device-links", ownerToken, map[string]interface{}{"code": strings.Repeat("b", 64)})
	if status != http.StatusCreated {
		t.Fatalf("create device link status=%d body=%s", status, response)
	}
	var created struct {
		DeviceLink struct {
			ID   string `json:"id"`
			Code string `json:"code"`
		} `json:"device_link"`
	}
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatal(err)
	}
	enrollment := reserveEnrollment(t, handler, "/api/v1/device-links/claim-enrollment", created.DeviceLink.Code)
	claimBody := map[string]interface{}{
		"code":               created.DeviceLink.Code,
		"device_name":        "linked tablet",
		"device_key_package": make([]byte, 64),
		"transcript_hash":    bytes.Repeat([]byte{7}, 32),
		"claim_tag":          bytes.Repeat([]byte{8}, 32),
	}
	addEnrollmentProof(claimBody, enrollment)
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/claim", "", claimBody)
	if status != http.StatusAccepted {
		t.Fatalf("claim device link status=%d body=%s", status, response)
	}
	var claimed struct {
		ClaimToken string `json:"claim_token"`
	}
	if err := json.Unmarshal(response, &claimed); err != nil {
		t.Fatal(err)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/"+created.DeviceLink.ID+"/approve", ownerToken, map[string]interface{}{
		"transcript_hash": bytes.Repeat([]byte{7}, 32),
		"approval_tag":    bytes.Repeat([]byte{9}, 32),
	})
	if status != http.StatusOK {
		t.Fatalf("approve device link status=%d body=%s", status, response)
	}

	if _, err := db.Exec(`CREATE TRIGGER hide_consumed_link AFTER UPDATE OF state ON device_links WHEN NEW.state = 'consumed'
		BEGIN UPDATE device_links SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = NEW.id; END`); err != nil {
		t.Fatal(err)
	}
	status, response = doRaw(t, handler, http.MethodGet, "/api/v1/device-links/"+created.DeviceLink.ID+"/claim-status", "", nil, map[string]string{
		"X-Veritra-Claim-Token": claimed.ClaimToken,
	})
	if status != http.StatusOK {
		t.Fatalf("claim-status status=%d body=%s, want 200 with the session token", status, response)
	}
	var completed struct {
		Token          string `json:"token"`
		TranscriptHash []byte `json:"transcript_hash"`
		ApprovalTag    []byte `json:"approval_tag"`
	}
	if err := json.Unmarshal(response, &completed); err != nil {
		t.Fatal(err)
	}
	if completed.Token == "" || !bytes.Equal(completed.TranscriptHash, bytes.Repeat([]byte{7}, 32)) || !bytes.Equal(completed.ApprovalTag, bytes.Repeat([]byte{9}, 32)) {
		t.Fatalf("incomplete claim-status response: %s", response)
	}
	if status, response = doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", completed.Token, nil); status != http.StatusOK {
		t.Fatalf("the committed session token does not work: status=%d body=%s", status, response)
	}
}
