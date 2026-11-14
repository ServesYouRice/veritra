package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// TASK-209 / D134 contract: GET /api/v1/sync/events is always bounded. A 200
// carries events, sync_epoch, scanned_through and scan_truncated and leaves
// the bounds out (they are read from a 409 only). ?scan=bounded is accepted
// and changes nothing, so a request without it gets the same page.
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
	plain := fields("/api/v1/sync/events?after=0&limit=200")
	bounded := fields("/api/v1/sync/events?after=0&limit=200&scan=bounded")
	for name, response := range map[string]map[string]json.RawMessage{"without scan=bounded": plain, "with scan=bounded": bounded} {
		for _, field := range []string{"events", "sync_epoch", "scanned_through", "scan_truncated"} {
			if _, ok := response[field]; !ok {
				t.Fatalf("%s: response lacks %s", name, field)
			}
		}
		for _, field := range []string{"oldest_event_id", "latest_event_id"} {
			if _, ok := response[field]; ok {
				t.Fatalf("%s: a 200 carries %s", name, field)
			}
		}
	}
	for _, field := range []string{"events", "sync_epoch", "scanned_through", "scan_truncated"} {
		if string(plain[field]) != string(bounded[field]) {
			t.Fatalf("%s differs with the opt-in: %s vs %s", field, plain[field], bounded[field])
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
