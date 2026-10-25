package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

type receiptsResponse struct {
	Receipts []struct {
		AccountID        string  `json:"account_id"`
		MemberSince      string  `json:"member_since"`
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

// waitDelivered polls until the first receipt listed to token has a delivery
// cursor: the server writes it just after the sync response.
func waitDelivered(t *testing.T, handler http.Handler, token, conversationID string) receiptsResponse {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		got := getReceipts(t, handler, token, conversationID)
		if len(got.Receipts) > 0 && got.Receipts[0].DeliveredThrough != nil {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("no delivery cursor appeared: %+v", got)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

func addMember(t *testing.T, handler http.Handler, ownerToken, conversationID, accountID string) {
	t.Helper()
	if status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{"account_id": accountID}); status >= 300 {
		t.Fatalf("add member status=%d body=%s", status, response)
	}
}

// Delivered follows the recipient's sync fetch and read follows its read
// receipt.
func TestReceiptsDeliveredAndRead(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	outsiderToken := registerMember(t, handler, ownerToken, "outsider")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	first := createMessage(t, handler, ownerToken, conversationID, "first", []byte("one"))

	got := getReceipts(t, handler, ownerToken, conversationID)
	if len(got.Receipts) != 1 || got.Receipts[0].AccountID != memberID ||
		got.Receipts[0].DeliveredThrough != nil || got.Receipts[0].ReadThrough != nil ||
		got.Receipts[0].MemberSince == "" {
		t.Fatalf("before any fetch: %+v", got)
	}

	if status, response := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", memberToken, nil); status != http.StatusOK {
		t.Fatalf("member sync status=%d body=%s", status, response)
	}
	got = waitDelivered(t, handler, ownerToken, conversationID)
	if got.Receipts[0].ReadThrough != nil {
		t.Fatalf("after sync: %+v", got)
	}

	path := "/api/v1/conversations/" + conversationID + "/read-receipts"
	if status, response := doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": first}); status != http.StatusNoContent {
		t.Fatalf("read status=%d body=%s", status, response)
	}
	if got = getReceipts(t, handler, ownerToken, conversationID); got.Receipts[0].ReadThrough == nil {
		t.Fatalf("after public read: %+v", got)
	}

	// Non-members cannot list cursors, and a member does not see itself.
	if status, _ := doJSON(t, handler, http.MethodGet, path, outsiderToken, nil); status != http.StatusForbidden {
		t.Fatalf("outsider list status=%d", status)
	}
	if got := getReceipts(t, handler, memberToken, conversationID); len(got.Receipts) != 1 || got.Receipts[0].AccountID == memberID {
		t.Fatalf("member list: %+v", got)
	}
}

// Switching receipts off freezes the cursor others see: later reads, however
// the app sends them, neither move it nor make it vanish, and are not
// announced. The member's own unread count still clears.
func TestReceiptsSwitchOffFreezesSharedCursor(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	first := createMessage(t, handler, ownerToken, conversationID, "first", []byte("one"))
	path := "/api/v1/conversations/" + conversationID + "/read-receipts"
	if status, response := doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": first}); status != http.StatusNoContent {
		t.Fatalf("read status=%d body=%s", status, response)
	}
	before := getReceipts(t, handler, ownerToken, conversationID)
	if before.Receipts[0].ReadThrough == nil {
		t.Fatalf("setup: no shared read")
	}

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
	second := createMessage(t, handler, ownerToken, conversationID, "second", []byte("two"))
	// Both a device that knows about the switch and one that does not.
	for _, body := range []map[string]interface{}{
		{"message_id": second},
		{"message_id": second, "private": true},
	} {
		if status, response = doJSON(t, handler, http.MethodPost, path, memberToken, body); status != http.StatusNoContent {
			t.Fatalf("read status=%d body=%s", status, response)
		}
	}
	after := getReceipts(t, handler, ownerToken, conversationID)
	if deref(after.Receipts[0].ReadThrough) != deref(before.Receipts[0].ReadThrough) {
		t.Fatalf("shared cursor changed with the switch off: before=%s after=%s",
			deref(before.Receipts[0].ReadThrough), deref(after.Receipts[0].ReadThrough))
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
			t.Fatalf("private read was announced: %s", response)
		}
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/conversations", memberToken, nil)
	if status != http.StatusOK || bytes.Contains(response, []byte(`"unread_count":1`)) {
		t.Fatalf("unread not cleared status=%d body=%s", status, response)
	}

	// Back on: the next read moves the shared cursor.
	if status, response = doJSON(t, handler, http.MethodPut, "/api/v1/account/read-receipts", memberToken, map[string]interface{}{"enabled": true}); status != http.StatusOK {
		t.Fatalf("switch on status=%d body=%s", status, response)
	}
	third := createMessage(t, handler, ownerToken, conversationID, "third", []byte("three"))
	if status, response = doJSON(t, handler, http.MethodPost, path, memberToken, map[string]interface{}{"message_id": third}); status != http.StatusNoContent {
		t.Fatalf("read again status=%d body=%s", status, response)
	}
	if got := getReceipts(t, handler, ownerToken, conversationID); deref(got.Receipts[0].ReadThrough) == deref(before.Receipts[0].ReadThrough) {
		t.Fatalf("shared cursor did not move after switching on: %+v", got)
	}
}

// A member added after earlier messages is told apart by member_since, so a
// reader can skip them for messages sent before they joined.
func TestReceiptsListMemberSince(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	_, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	conversationID := createConversation(t, handler, ownerToken)
	before := time.Now().UTC().Add(-time.Second)
	createMessage(t, handler, ownerToken, conversationID, "early", []byte("x"))
	time.Sleep(5 * time.Millisecond)
	addMember(t, handler, ownerToken, conversationID, memberID)
	got := getReceipts(t, handler, ownerToken, conversationID)
	if len(got.Receipts) != 1 {
		t.Fatalf("receipts: %+v", got)
	}
	since, err := time.Parse(time.RFC3339Nano, got.Receipts[0].MemberSince)
	if err != nil || !since.After(before) {
		t.Fatalf("member_since %q err=%v", got.Receipts[0].MemberSince, err)
	}
}

// A block hides cursors in both directions, in the listing. The cursors
// exist (an unblocked viewer, the owner, sees both), so the hidden listing is
// not an empty one.
func TestReceiptsBlockHidesCursorsBothWays(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	aToken, aID := registerMemberWithID(t, handler, ownerToken, "alice")
	bToken, bID := registerMemberWithID(t, handler, ownerToken, "bob")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, aID)
	addMember(t, handler, ownerToken, conversationID, bID)
	// Bob blocks Alice.
	if status, body := doJSON(t, handler, http.MethodPut, "/api/v1/account/blocks/"+aID, bToken, nil); status >= 300 {
		t.Fatalf("block %d %s", status, body)
	}
	createMessage(t, handler, aToken, conversationID, "from-alice", []byte("a"))
	fromOwner := createMessage(t, handler, ownerToken, conversationID, "from-owner", []byte("o"))
	doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", bToken, nil)
	doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", aToken, nil)
	readPath := "/api/v1/conversations/" + conversationID + "/read-receipts"
	for _, token := range []string{aToken, bToken} {
		if status, body := doJSON(t, handler, http.MethodPost, readPath, token, map[string]interface{}{"message_id": fromOwner}); status != http.StatusNoContent {
			t.Fatalf("read %d %s", status, body)
		}
	}
	// Wait until the owner sees a delivery and a read cursor for both.
	deadline := time.Now().Add(3 * time.Second)
	for {
		seen := 0
		for _, r := range getReceipts(t, handler, ownerToken, conversationID).Receipts {
			if r.DeliveredThrough != nil && r.ReadThrough != nil {
				seen++
			}
		}
		if seen == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("owner never saw both cursors: %+v", getReceipts(t, handler, ownerToken, conversationID))
		}
		time.Sleep(20 * time.Millisecond)
	}
	for name, token := range map[string]string{"alice": aToken, "bob": bToken} {
		other := bID
		if name == "bob" {
			other = aID
		}
		for _, r := range getReceipts(t, handler, token, conversationID).Receipts {
			if r.AccountID == other {
				t.Errorf("%s still sees the cursors of the account in a block with them", name)
			}
		}
	}
}

// Removing a member deletes their cursors, so adding them back later does not
// bring old ones back.
func TestReceiptsRemovedMemberCursorsAreDeleted(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	m := createMessage(t, handler, ownerToken, conversationID, "m", []byte("x"))
	doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", memberToken, nil)
	waitDelivered(t, handler, ownerToken, conversationID)
	doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/read-receipts", memberToken, map[string]interface{}{"message_id": m})
	if status, body := doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+conversationID+"/members/"+memberID, ownerToken, nil); status >= 300 {
		t.Fatalf("remove status=%d body=%s", status, body)
	}
	addMember(t, handler, ownerToken, conversationID, memberID)
	got := getReceipts(t, handler, ownerToken, conversationID)
	for _, r := range got.Receipts {
		if r.AccountID == memberID && (r.DeliveredThrough != nil || r.ReadThrough != nil) {
			t.Fatalf("cursors from before removal came back: %+v", r)
		}
	}
}

// The sender's own sync fetch never records delivery for its own messages.
func TestReceiptsSenderFetchIsNotDelivery(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	createMessage(t, handler, memberToken, conversationID, "from-member", []byte("hello"))
	if status, response := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", memberToken, nil); status != http.StatusOK {
		t.Fatalf("member sync status=%d body=%s", status, response)
	}
	time.Sleep(200 * time.Millisecond)
	got := getReceipts(t, handler, ownerToken, conversationID)
	if got.Receipts[0].DeliveredThrough != nil {
		t.Fatalf("sender fetch counted as delivery: %+v", got)
	}
}
