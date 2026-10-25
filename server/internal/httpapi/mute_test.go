package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// W6: mute for 8 hours, 1 week or always. The flag alone still means always,
// so clients that predate timed mutes keep working.
func TestConversationMuteDurations(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwnerDevice(t)
	conversationID := createConversation(t, handler, token)
	path := "/api/v1/conversations/" + conversationID + "/notifications"

	status, response := doJSON(t, handler, http.MethodGet, path, token, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(`"muted":false`)) {
		t.Fatalf("initial status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPut, path, token, map[string]interface{}{"muted": true})
	if status != http.StatusOK || bytes.Contains(response, []byte("muted_until")) {
		t.Fatalf("mute always status=%d body=%s", status, response)
	}
	until := time.Now().Add(8 * time.Hour).UTC().Truncate(time.Second)
	status, response = doJSON(t, handler, http.MethodPut, path, token, map[string]interface{}{
		"muted": true, "muted_until": until.Format(time.RFC3339),
	})
	if status != http.StatusOK {
		t.Fatalf("mute 8h status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, path, token, nil)
	var got struct {
		Muted bool       `json:"muted"`
		Until *time.Time `json:"muted_until"`
	}
	if err := json.Unmarshal(response, &got); err != nil || status != http.StatusOK || !got.Muted || got.Until == nil || !got.Until.Equal(until) {
		t.Fatalf("get status=%d body=%s", status, response)
	}
	// A length counts from the server's clock.
	status, response = doJSON(t, handler, http.MethodPut, path, token, map[string]interface{}{"muted": true, "muted_for_seconds": 7 * 24 * 3600})
	if status != http.StatusOK {
		t.Fatalf("mute 1 week status=%d body=%s", status, response)
	}
	var week struct {
		Until *time.Time `json:"muted_until"`
	}
	if err := json.Unmarshal(response, &week); err != nil || week.Until == nil || time.Until(*week.Until) < 6*24*time.Hour || time.Until(*week.Until) > 8*24*time.Hour {
		t.Fatalf("1 week body=%s", response)
	}
	for _, seconds := range []int64{0, -5, 400 * 24 * 3600} {
		status, response = doJSON(t, handler, http.MethodPut, path, token, map[string]interface{}{"muted": true, "muted_for_seconds": seconds})
		if status != http.StatusBadRequest || !bytes.Contains(response, []byte("muted_until_invalid")) {
			t.Fatalf("seconds %d: status=%d body=%s", seconds, status, response)
		}
	}
	for name, value := range map[string]string{
		"past":    time.Now().Add(-time.Hour).UTC().Format(time.RFC3339),
		"too far": time.Now().Add(400 * 24 * time.Hour).UTC().Format(time.RFC3339),
	} {
		status, response = doJSON(t, handler, http.MethodPut, path, token, map[string]interface{}{"muted": true, "muted_until": value})
		if status != http.StatusBadRequest || !bytes.Contains(response, []byte("muted_until_invalid")) {
			t.Fatalf("%s: status=%d body=%s", name, status, response)
		}
	}
	status, response = doJSON(t, handler, http.MethodPut, path, token, map[string]interface{}{"muted": false})
	if status != http.StatusOK {
		t.Fatalf("unmute status=%d body=%s", status, response)
	}
	_, response = doJSON(t, handler, http.MethodGet, path, token, nil)
	if !bytes.Contains(response, []byte(`"muted":false`)) || bytes.Contains(response, []byte("muted_until")) {
		t.Fatalf("after unmute body=%s", response)
	}
}
