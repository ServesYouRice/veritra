package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"private-messenger/server/internal/realtime"
)

// syncReadReceiptAccounts lists the accounts whose read_receipt.updated
// events a full sync from the start returns to token.
func syncReadReceiptAccounts(t *testing.T, handler http.Handler, token string) map[string]bool {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=100", token, nil)
	if status != http.StatusOK {
		t.Fatalf("sync status=%d body=%s", status, response)
	}
	var decoded struct {
		Events []struct {
			Type    string `json:"type"`
			Payload struct {
				AccountID string `json:"account_id"`
			} `json:"payload"`
		} `json:"events"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatalf("decode sync: %v", err)
	}
	got := map[string]bool{}
	for _, event := range decoded.Events {
		if event.Type == "read_receipt.updated" {
			got[event.Payload.AccountID] = true
		}
	}
	return got
}

// D48: a block hides read receipts and typing in both directions, in the
// realtime fan-out and in sync. Bob blocks Alice; the owner is unblocked and
// shows each signal was sent at all.
func TestBlockHidesReadReceiptsAndTypingBothWays(t *testing.T) {
	application, handler, ownerToken, _ := newTestAppWithOwner(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	aToken, aID := registerMemberWithID(t, handler, ownerToken, "alice")
	bToken, bID := registerMemberWithID(t, handler, ownerToken, "bob")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, aID)
	addMember(t, handler, ownerToken, conversationID, bID)
	if status, body := doJSON(t, handler, http.MethodPut, "/api/v1/account/blocks/"+aID, bToken, nil); status >= 300 {
		t.Fatalf("block %d %s", status, body)
	}
	message := createMessage(t, handler, ownerToken, conversationID, "from-owner", []byte("o"))

	clients := map[string]*realtime.Client{}
	for id, ip := range map[string]string{ownerID: "10.0.0.1", aID: "10.0.0.2", bID: "10.0.0.3"} {
		client, err := application.Hub.Register(id, "dev-"+id, ip)
		if err != nil {
			t.Fatalf("register realtime client: %v", err)
		}
		t.Cleanup(client.Close)
		clients[id] = client
	}

	readPath := "/api/v1/conversations/" + conversationID + "/read-receipts"
	typingPath := "/api/v1/conversations/" + conversationID + "/typing"
	for _, token := range []string{aToken, bToken} {
		if status, body := doJSON(t, handler, http.MethodPost, readPath, token, map[string]interface{}{"message_id": message}); status != http.StatusNoContent {
			t.Fatalf("read %d %s", status, body)
		}
		if status, body := doJSON(t, handler, http.MethodPost, typingPath, token, nil); status != http.StatusNoContent {
			t.Fatalf("typing %d %s", status, body)
		}
	}

	// Realtime: both signals of both reach the owner; Alice and Bob get
	// neither of the other (Alice's own devices still get her receipt).
	wantReceipts := map[string]map[string]bool{
		ownerID: {aID: true, bID: true},
		aID:     {aID: true},
		bID:     {bID: true},
	}
	wantTyping := map[string]map[string]bool{
		ownerID: {aID: true, bID: true},
		aID:     {},
		bID:     {},
	}
	for id, client := range clients {
		receipts, typing := drainBoth(t, client)
		if !sameSet(receipts, wantReceipts[id]) {
			t.Errorf("realtime read receipts for %s = %v, want %v", id, receipts, wantReceipts[id])
		}
		if !sameSet(typing, wantTyping[id]) {
			t.Errorf("realtime typing for %s = %v, want %v", id, typing, wantTyping[id])
		}
	}

	// Sync: the same visibility from the stored events.
	for id, token := range map[string]string{ownerID: ownerToken, aID: aToken, bID: bToken} {
		if got := syncReadReceiptAccounts(t, handler, token); !sameSet(got, wantReceipts[id]) {
			t.Errorf("sync read receipts for %s = %v, want %v", id, got, wantReceipts[id])
		}
	}
	// Unblocking brings them back on the next sync (the hide is a read-time
	// filter, not a deletion).
	if status, body := doJSON(t, handler, http.MethodDelete, "/api/v1/account/blocks/"+aID, bToken, nil); status >= 300 {
		t.Fatalf("unblock %d %s", status, body)
	}
	if got := syncReadReceiptAccounts(t, handler, aToken); !sameSet(got, map[string]bool{aID: true, bID: true}) {
		t.Errorf("sync read receipts after unblock = %v", got)
	}
}

// drainBoth returns the account ids of the read receipt and typing events
// queued for client.
func drainBoth(t *testing.T, client *realtime.Client) (map[string]bool, map[string]bool) {
	t.Helper()
	receipts, typing := map[string]bool{}, map[string]bool{}
	deadline := time.After(50 * time.Millisecond)
	for {
		select {
		case raw := <-client.Send():
			var event struct {
				Type    string `json:"type"`
				Payload struct {
					AccountID string `json:"account_id"`
				} `json:"payload"`
			}
			if err := json.Unmarshal(raw, &event); err != nil {
				t.Fatalf("decode realtime event: %v", err)
			}
			switch event.Type {
			case "read_receipt.updated":
				receipts[event.Payload.AccountID] = true
			case "typing.updated":
				typing[event.Payload.AccountID] = true
			}
		case <-deadline:
			return receipts, typing
		}
	}
}

func sameSet(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}
