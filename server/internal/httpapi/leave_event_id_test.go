package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// TestLeaveResponseEventIDIsTheLeaversMembershipLeftEvent pins the exact
// floor the mobile app dates a leave by (D70): the DELETE /members/me
// response carries the id of the leaver's own membership.left sync event,
// and a Welcome stored for the leaver before the leave has a lower id.
func TestLeaveResponseEventIDIsTheLeaversMembershipLeftEvent(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "exactleaver")
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind":               "group",
		"member_account_ids": []string{memberID},
	})
	if status != http.StatusCreated {
		t.Fatalf("create group status=%d body=%s", status, response)
	}
	var group struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &group); err != nil {
		t.Fatalf("decode group: %v", err)
	}
	createMessage(t, handler, ownerToken, group.ID, "before-leave", []byte("ciphertext"))

	status, response = doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+group.ID+"/members/me", memberToken, nil)
	if status != http.StatusOK {
		t.Fatalf("leave status=%d body=%s", status, response)
	}
	var left struct {
		Status          string `json:"status"`
		MLSCoordination string `json:"mls_coordination"`
		EventID         int64  `json:"event_id"`
	}
	if err := json.Unmarshal(response, &left); err != nil {
		t.Fatalf("decode leave: %v", err)
	}
	if left.Status != "membership_removed" || left.MLSCoordination != "pending" {
		t.Fatalf("existing leave fields changed: %s", response)
	}
	if left.EventID <= 0 {
		t.Fatalf("leave response has no event_id: %s", response)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=200", memberToken, nil)
	if status != http.StatusOK {
		t.Fatalf("sync status=%d body=%s", status, response)
	}
	var synced struct {
		Events []struct {
			ID   int64  `json:"id"`
			Type string `json:"type"`
		} `json:"events"`
	}
	if err := json.Unmarshal(response, &synced); err != nil {
		t.Fatalf("decode sync: %v", err)
	}
	var leftID int64
	for _, event := range synced.Events {
		if event.Type == "membership.left" {
			leftID = event.ID
		}
	}
	if leftID == 0 {
		t.Fatal("the leaver was not sent its membership.left event")
	}
	if left.EventID != leftID {
		t.Fatalf("event_id=%d, the leaver's membership.left event is %d", left.EventID, leftID)
	}
	// Everything the leaver was ever sent before the leave is below it.
	for _, event := range synced.Events {
		if event.ID > left.EventID && event.Type != "membership.left" {
			t.Fatalf("event %d (%s) above the leave id %d was sent to the leaver", event.ID, event.Type, left.EventID)
		}
	}
}
