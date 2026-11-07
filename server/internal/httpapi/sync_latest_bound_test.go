package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// TestSyncLatestBoundPastEveryCursorCoversALeave pins what the mobile app
// relies on to date a leave (D70): a page requested past every event id is
// a normal 200 with no events, and its latest_event_id is at or above the
// leaver's own membership.left event, even though the conversation no
// longer counts for the account. The request moves no cursor.
func TestSyncLatestBoundPastEveryCursorCoversALeave(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "latestleaver")
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
	// Newer events in the conversation the member left do not reach it.
	createMessage(t, handler, ownerToken, group.ID, "after-leave", []byte("ciphertext"))

	type page struct {
		Events []struct {
			ID   int64  `json:"id"`
			Type string `json:"type"`
		} `json:"events"`
		Latest int64 `json:"latest_event_id"`
	}
	read := func(path string) page {
		t.Helper()
		status, response := doJSON(t, handler, http.MethodGet, path, memberToken, nil)
		if status != http.StatusOK {
			t.Fatalf("GET %s status=%d body=%s", path, status, response)
		}
		var decoded page
		if err := json.Unmarshal(response, &decoded); err != nil {
			t.Fatalf("decode %s: %v", path, err)
		}
		return decoded
	}

	var leftID int64
	for _, event := range read("/api/v1/sync/events?after=0&limit=200").Events {
		if event.Type == "membership.left" {
			leftID = event.ID
		}
	}
	if leftID == 0 {
		t.Fatal("the leaver was not sent its membership.left event")
	}

	const pastEverything = "9007199254740991"
	bound := read("/api/v1/sync/events?after=" + pastEverything + "&limit=1")
	if len(bound.Events) != 0 {
		t.Fatalf("a cursor past every event returned %d events", len(bound.Events))
	}
	if bound.Latest < leftID {
		t.Fatalf("latest_event_id=%d is below the leave event %d", bound.Latest, leftID)
	}

	// Asking moved nothing: a read from the start still returns the leave.
	again := read("/api/v1/sync/events?after=0&limit=200")
	found := false
	for _, event := range again.Events {
		found = found || event.ID == leftID
	}
	if !found {
		t.Fatal("the bound request changed what the device is served")
	}
}

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
