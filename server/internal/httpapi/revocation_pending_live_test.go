package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"private-messenger/server/internal/realtime"
)

// drainRevocationPending counts the live mls.revocation.pending events a
// socket received and returns the last one's conversation and payload.
func drainRevocationPending(t *testing.T, client *realtime.Client) (count int, conversationID string, payload map[string]string) {
	t.Helper()
	deadline := time.After(100 * time.Millisecond)
	for {
		select {
		case raw := <-client.Send():
			var event struct {
				Type           string          `json:"type"`
				ConversationID string          `json:"conversation_id"`
				Payload        json.RawMessage `json:"payload"`
			}
			if err := json.Unmarshal(raw, &event); err != nil {
				t.Fatalf("decode realtime event: %v", err)
			}
			if event.Type == "mls.revocation.pending" {
				count++
				conversationID = event.ConversationID
				if err := json.Unmarshal(event.Payload, &payload); err != nil {
					t.Fatalf("decode revocation payload: %v", err)
				}
			}
		case <-deadline:
			return count, conversationID, payload
		}
	}
}

// Found live in the L1-5 run (mobile/test/l1_live_e2e_test.dart): revoking a
// device queued its group's revocation but told nobody live, so a
// coordinator on another account committed the removal only at its next
// catch-up for some other reason, minutes later or never in an idle chat,
// and messages sent meanwhile were still encrypted to the revoked leaf. The
// revocation is now announced live to the group's members, as its
// completion already is; an outsider hears nothing.
func TestDeviceRevocationAnnouncesPendingRevocationLive(t *testing.T) {
	application, handler, ownerToken, _ := newTestAppWithOwner(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	bobToken, bobID := registerMemberWithID(t, handler, ownerToken, "bob")
	_, outsiderID := registerMemberWithID(t, handler, ownerToken, "outsider")
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
	outsider, err := application.Hub.Register(outsiderID, "dev_outsider", "10.0.0.3")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(outsider.Close)

	if status, body := doJSON(t, handler, http.MethodDelete, "/api/v1/devices/"+bobDevice, bobToken, nil); status != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", status, body)
	}

	count, conversation, payload := drainRevocationPending(t, owner)
	if count != 1 || conversation != conversationID {
		t.Fatalf("live revocation events to the coordinator = %d for %q, want one for %q", count, conversation, conversationID)
	}
	if len(payload) != 2 || payload["device_id"] != bobDevice || payload["account_id"] != bobID {
		t.Fatalf("payload = %v, want the durable event's device and account only", payload)
	}
	if count, _, _ := drainRevocationPending(t, outsider); count != 0 {
		t.Fatalf("an account outside the conversation heard %d revocations", count)
	}
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", ownerToken, nil)
	if status != http.StatusOK || bytes.Count(response, []byte(`"mls.revocation.pending"`)) != 1 {
		t.Fatalf("sync status=%d body=%s, want the one durable event", status, response)
	}
}
