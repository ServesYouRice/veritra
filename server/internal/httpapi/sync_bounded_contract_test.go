package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// TASK-209 contract: GET /api/v1/sync/events?scan=bounded adds
// scanned_through and scan_truncated and leaves the bounds out of a 200
// (they are read from a 409 only). Without scan=bounded the response is the
// legacy one: the bounds, no scan fields.
func TestSyncEventsBoundedContract(t *testing.T) {
	_, handler, token, _ := newTestAppWithOwner(t)
	conversationID := createConversation(t, handler, token)
	createMessage(t, handler, token, conversationID, "bounded-contract", []byte("ciphertext"))

	fields := func(path string) map[string]json.RawMessage {
		t.Helper()
		status, body := doJSON(t, handler, http.MethodGet, path, token, nil)
		if status != http.StatusOK {
			t.Fatalf("%s: %d %s", path, status, body)
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(body, &raw); err != nil {
			t.Fatal(err)
		}
		return raw
	}
	legacy := fields("/api/v1/sync/events?after=0&limit=200")
	for _, name := range []string{"events", "sync_epoch", "oldest_event_id", "latest_event_id"} {
		if _, ok := legacy[name]; !ok {
			t.Fatalf("legacy response lost %s", name)
		}
	}
	for _, name := range []string{"scanned_through", "scan_truncated"} {
		if _, ok := legacy[name]; ok {
			t.Fatalf("legacy response grew %s", name)
		}
	}
	bounded := fields("/api/v1/sync/events?after=0&limit=200&scan=bounded")
	for _, name := range []string{"events", "sync_epoch", "scanned_through", "scan_truncated"} {
		if _, ok := bounded[name]; !ok {
			t.Fatalf("bounded response lacks %s", name)
		}
	}
	for _, name := range []string{"oldest_event_id", "latest_event_id"} {
		if _, ok := bounded[name]; ok {
			t.Fatalf("bounded 200 carries %s", name)
		}
	}
	if string(bounded["scan_truncated"]) != "false" {
		t.Fatalf("scan_truncated = %s", bounded["scan_truncated"])
	}
	var events []struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(bounded["events"], &events); err != nil || len(events) == 0 {
		t.Fatalf("events = %s, %v", bounded["events"], err)
	}
	if string(bounded["scanned_through"]) != jsonInt(events[len(events)-1].ID) {
		t.Fatalf("scanned_through = %s, want the last event %d", bounded["scanned_through"], events[len(events)-1].ID)
	}
	// Past the end: never below the cursor.
	past := fields("/api/v1/sync/events?after=999999&scan=bounded")
	if string(past["scanned_through"]) != "999999" {
		t.Fatalf("scanned_through past the end = %s", past["scanned_through"])
	}
}

func jsonInt(v int64) string {
	b, _ := json.Marshal(v)
	return string(b)
}
