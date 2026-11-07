package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/mlswire/mlswiretest"
	"private-messenger/server/internal/realtime"
)

// linkLegacyDevice links a tablet to the token's account through the legacy v2
// route, the one the shipped app approves with.
func linkLegacyDevice(t *testing.T, handler http.Handler, token string, codeByte string) {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/device-links", token, map[string]interface{}{"code": strings.Repeat(codeByte, 64)})
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
		"device_key_package": mlswiretest.KeyPackage(),
		"transcript_hash":    bytes.Repeat([]byte{7}, 32),
		"claim_tag":          bytes.Repeat([]byte{8}, 32),
	}
	addEnrollmentProof(claimBody, enrollment)
	if status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/claim", "", claimBody); status != http.StatusAccepted {
		t.Fatalf("claim device link status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/"+created.DeviceLink.ID+"/approve", token, map[string]interface{}{
		"transcript_hash": bytes.Repeat([]byte{7}, 32),
		"approval_tag":    bytes.Repeat([]byte{9}, 32),
	})
	if status != http.StatusOK {
		t.Fatalf("approve device link status=%d body=%s", status, response)
	}
}

func firstDeviceID(t *testing.T, handler http.Handler, token string) string {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", token, nil)
	var devices struct {
		Devices []struct {
			ID string `json:"id"`
		} `json:"devices"`
	}
	if status != http.StatusOK || json.Unmarshal(response, &devices) != nil || len(devices.Devices) == 0 {
		t.Fatalf("devices status=%d body=%s", status, response)
	}
	return devices.Devices[0].ID
}

func drainMemberLinked(t *testing.T, client *realtime.Client) (count int, payload map[string]string) {
	t.Helper()
	deadline := time.After(100 * time.Millisecond)
	for {
		select {
		case raw := <-client.Send():
			var event struct {
				Type    string          `json:"type"`
				Payload json.RawMessage `json:"payload"`
			}
			if err := json.Unmarshal(raw, &event); err != nil {
				t.Fatalf("decode realtime event: %v", err)
			}
			if event.Type == "device.member_linked" {
				count++
				if err := json.Unmarshal(event.Payload, &payload); err != nil {
					t.Fatalf("decode notice payload: %v", err)
				}
			}
		case <-deadline:
			return count, payload
		}
	}
}

// D96 on the route the shipped app uses: approving a legacy v2 device link
// tells the group's coordinator account (live and in sync), and nobody else.
// Which of the two accounts coordinates depends on the generated device ids,
// so both link a device: exactly one notice results, to the coordinator, about
// the other account.
func TestLegacyDeviceLinkApprovalNotifiesGroupCoordinator(t *testing.T) {
	application, handler, ownerToken, _ := newTestAppWithOwner(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	bobToken, bobID := registerMemberWithID(t, handler, ownerToken, "bob")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, bobID)
	ownerDevice, bobDevice := firstDeviceID(t, handler, ownerToken), firstDeviceID(t, handler, bobToken)
	commits := "/api/v1/conversations/" + conversationID + "/mls/commits"
	if status, body := doJSON(t, handler, http.MethodPost, commits, ownerToken, map[string]interface{}{"epoch": 0, "idempotency_key": "genesis"}); status != http.StatusCreated {
		t.Fatalf("genesis status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/key-packages/claim", ownerToken,
		map[string]interface{}{"device_ids": []string{bobDevice}}); status != http.StatusOK {
		t.Fatalf("claim status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodPost, commits, ownerToken, map[string]interface{}{
		"epoch": 0, "idempotency_key": "add-bob",
		"commit":  base64.StdEncoding.EncodeToString([]byte("commit")),
		"welcome": base64.StdEncoding.EncodeToString([]byte("welcome")),
		"added":   []map[string]string{{"account_id": bobID, "device_id": bobDevice}},
	}); status != http.StatusCreated {
		t.Fatalf("add bob status=%d body=%s", status, body)
	}

	owner, err := application.Hub.Register(ownerID, ownerDevice, "10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(owner.Close)
	bob, err := application.Hub.Register(bobID, bobDevice, "10.0.0.2")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bob.Close)

	linkLegacyDevice(t, handler, ownerToken, "a")
	linkLegacyDevice(t, handler, bobToken, "b")

	ownerCount, ownerPayload := drainMemberLinked(t, owner)
	bobCount, bobPayload := drainMemberLinked(t, bob)
	if ownerCount+bobCount != 1 {
		t.Fatalf("live notices owner=%d bob=%d, want exactly one", ownerCount, bobCount)
	}
	coordinatorToken, linkedID, payload := ownerToken, bobID, ownerPayload
	if bobCount == 1 {
		coordinatorToken, linkedID, payload = bobToken, ownerID, bobPayload
	}
	if len(payload) != 2 || payload["account_id"] != linkedID || payload["device_id"] == "" {
		t.Fatalf("payload = %v, want the linking account and device only", payload)
	}
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", coordinatorToken, nil)
	if status != http.StatusOK || bytes.Count(response, []byte(`"device.member_linked"`)) != 1 {
		t.Fatalf("sync status=%d body=%s, want one device.member_linked", status, response)
	}
}
