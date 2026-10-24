package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

type receiptsResponse struct {
	Receipts []struct {
		AccountID        string  `json:"account_id"`
		DeliveredThrough *string `json:"delivered_through"`
		ReadThrough      *string `json:"read_through"`
	} `json:"receipts"`
}

func getReceipts(t *testing.T, handler http.Handler, token, conversationID string) receiptsResponse {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+conversationID+"/read-receipts", token, nil)
	if status != http.StatusOK {
		t.Fatalf("list receipts status=%d body=%s", status, response)
	}
	var decoded receiptsResponse
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatalf("decode receipts: %v", err)
	}
	return decoded
}

// Delivered follows the recipient's sync fetch, read follows its read
// receipt, and a private receipt moves only the recipient's own cursor.
func TestReceiptsDeliveredReadAndPrivate(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	outsiderToken := registerMember(t, handler, ownerToken, "outsider")
	conversationID := createConversation(t, handler, ownerToken)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{"account_id": memberID})
	if status != http.StatusCreated && status != http.StatusOK && status != http.StatusNoContent {
		t.Fatalf("add member status=%d body=%s", status, response)
	}
	first := createMessage(t, handler, ownerToken, conversationID, "first", []byte("one"))
	second := createMessage(t, handler, ownerToken, conversationID, "second", []byte("two"))

	got := getReceipts(t, handler, ownerToken, conversationID)
	if len(got.Receipts) != 1 || got.Receipts[0].AccountID != memberID ||
		got.Receipts[0].DeliveredThrough != nil || got.Receipts[0].ReadThrough != nil {
		t.Fatalf("before any fetch: %+v", got)
	}

	// Serving the member's sync page is the delivery.
	if status, response = doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", memberToken, nil); status != http.StatusOK {
		t.Fatalf("member sync status=%d body=%s", status, response)
	}
	got = getReceipts(t, handler, ownerToken, conversationID)
	if got.Receipts[0].DeliveredThrough == nil || got.Receipts[0].ReadThrough != nil {
		t.Fatalf("after sync: %+v", got)
	}

	// A public read receipt for the first message covers it, not the second.
	path := "/api/v1/conversations/" + conversationID + "/read-receipts"
	if status, response = doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": first}); status != http.StatusNoContent {
		t.Fatalf("read status=%d body=%s", status, response)
	}
	got = getReceipts(t, handler, ownerToken, conversationID)
	if got.Receipts[0].ReadThrough == nil {
		t.Fatalf("after public read: %+v", got)
	}
	firstRead := *got.Receipts[0].ReadThrough

	// A private receipt for the newer message hides the read state and
	// publishes nothing: the owner sees no read cursor at all.
	if status, response = doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": second, "private": true}); status != http.StatusNoContent {
		t.Fatalf("private read status=%d body=%s", status, response)
	}
	got = getReceipts(t, handler, ownerToken, conversationID)
	if got.Receipts[0].ReadThrough != nil || got.Receipts[0].DeliveredThrough == nil {
		t.Fatalf("after private read: %+v", got)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("owner sync status=%d body=%s", status, response)
	}
	var events struct {
		Events []struct {
			Type    string `json:"type"`
			Payload struct {
				MessageID string `json:"message_id"`
			} `json:"payload"`
		} `json:"events"`
	}
	if err := json.Unmarshal(response, &events); err != nil {
		t.Fatalf("decode events: %v", err)
	}
	for _, event := range events.Events {
		if event.Type == "read_receipt.updated" && event.Payload.MessageID == second {
			t.Fatalf("private receipt was announced: %s", response)
		}
	}

	// Switching receipts back on shares the same cursor again.
	if status, response = doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": second}); status != http.StatusNoContent {
		t.Fatalf("public read again status=%d body=%s", status, response)
	}
	got = getReceipts(t, handler, ownerToken, conversationID)
	if got.Receipts[0].ReadThrough == nil || *got.Receipts[0].ReadThrough == firstRead {
		t.Fatalf("after switching back on: %+v", got)
	}

	// Non-members cannot list cursors, and a member does not see itself.
	if status, _ = doJSON(t, handler, http.MethodGet, path, outsiderToken, nil); status != http.StatusForbidden {
		t.Fatalf("outsider list status=%d", status)
	}
	if got := getReceipts(t, handler, memberToken, conversationID); len(got.Receipts) != 1 || got.Receipts[0].AccountID == memberID {
		t.Fatalf("member list: %+v", got)
	}
}

// The switch belongs to the account: once it is off the server keeps every
// receipt private, whatever the device asks, and nothing is announced.
func TestReceiptsAccountSwitchForcesPrivate(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	conversationID := createConversation(t, handler, ownerToken)
	if status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{"account_id": memberID}); status >= 300 {
		t.Fatalf("add member status=%d body=%s", status, response)
	}
	messageID := createMessage(t, handler, ownerToken, conversationID, "m", []byte("hi"))

	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/account/read-receipts", memberToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(`"enabled":true`)) {
		t.Fatalf("default setting status=%d body=%s", status, response)
	}
	if status, response = doJSON(t, handler, http.MethodPut, "/api/v1/account/read-receipts", memberToken, map[string]interface{}{}); status != http.StatusBadRequest {
		t.Fatalf("missing field status=%d body=%s", status, response)
	}
	if status, response = doJSON(t, handler, http.MethodPut, "/api/v1/account/read-receipts", memberToken, map[string]interface{}{"enabled": false}); status != http.StatusOK {
		t.Fatalf("switch off status=%d body=%s", status, response)
	}
	// A device that does not know about the switch sends a public receipt.
	path := "/api/v1/conversations/" + conversationID + "/read-receipts"
	if status, response = doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": messageID}); status != http.StatusNoContent {
		t.Fatalf("read status=%d body=%s", status, response)
	}
	if got := getReceipts(t, handler, ownerToken, conversationID); got.Receipts[0].ReadThrough != nil {
		t.Fatalf("receipt leaked with the switch off: %+v", got)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", ownerToken, nil)
	if status != http.StatusOK || bytes.Contains(response, []byte("read_receipt.updated")) {
		t.Fatalf("owner sync status=%d body=%s", status, response)
	}
	// The member's own unread count still clears.
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/conversations", memberToken, nil)
	if status != http.StatusOK || bytes.Contains(response, []byte(`"unread_count":1`)) {
		t.Fatalf("unread not cleared status=%d body=%s", status, response)
	}
	// Back on: the next receipt is shared.
	if status, response = doJSON(t, handler, http.MethodPut, "/api/v1/account/read-receipts", memberToken, map[string]interface{}{"enabled": true}); status != http.StatusOK {
		t.Fatalf("switch on status=%d body=%s", status, response)
	}
	if status, response = doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": messageID}); status != http.StatusNoContent {
		t.Fatalf("read again status=%d body=%s", status, response)
	}
	if got := getReceipts(t, handler, ownerToken, conversationID); got.Receipts[0].ReadThrough == nil {
		t.Fatalf("receipt not shared after switching on: %+v", got)
	}
}

// The listing applies the same block filter as the sync events: an account
// the caller blocked leaves no cursor behind in it.
func TestReceiptsListSkipsBlockedAccounts(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	_, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	conversationID := createConversation(t, handler, ownerToken)
	if status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{"account_id": memberID}); status >= 300 {
		t.Fatalf("add member status=%d body=%s", status, response)
	}
	if got := getReceipts(t, handler, ownerToken, conversationID); len(got.Receipts) != 1 {
		t.Fatalf("before block: %+v", got)
	}
	if status, response := doJSON(t, handler, http.MethodPut, "/api/v1/account/blocks/"+memberID, ownerToken, nil); status >= 300 {
		t.Fatalf("block status=%d body=%s", status, response)
	}
	if got := getReceipts(t, handler, ownerToken, conversationID); len(got.Receipts) != 0 {
		t.Fatalf("after block: %+v", got)
	}
}

// The sender's own sync fetch never records delivery for its own messages.
func TestReceiptsSenderFetchIsNotDelivery(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	conversationID := createConversation(t, handler, ownerToken)
	if status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{"account_id": memberID}); status >= 300 {
		t.Fatalf("add member status=%d body=%s", status, response)
	}
	createMessage(t, handler, memberToken, conversationID, "from-member", []byte("hello"))
	if status, response := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", memberToken, nil); status != http.StatusOK {
		t.Fatalf("member sync status=%d body=%s", status, response)
	}
	got := getReceipts(t, handler, ownerToken, conversationID)
	if got.Receipts[0].DeliveredThrough != nil {
		t.Fatalf("sender fetch counted as delivery: %+v", got)
	}
}
