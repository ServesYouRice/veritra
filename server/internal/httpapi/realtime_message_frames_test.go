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

// A new, an edited and a deleted message each reach live sockets as one
// bare frame that only says sync has something new: no event id, no
// conversation id and no envelope, and the same bytes for all three apart
// from created_at. Sync is where the envelope comes from, under the join
// filter and C7's targeting (I51), so the socket can no longer hand a device
// a body sync would withhold, and the kinds cannot be told apart.
func TestMessageFramesAreBareSyncAvailableEvents(t *testing.T) {
	application, handler, token, _ := newTestAppWithOwner(t)
	ownerID := accountIDFromExport(t, handler, token)
	client, err := application.Hub.Register(ownerID, "dev-other", "10.0.0.9")
	if err != nil {
		t.Fatalf("register realtime client: %v", err)
	}
	t.Cleanup(client.Close)
	conversationID := createConversation(t, handler, token)
	messageID := createMessage(t, handler, token, conversationID, "frames-1", []byte("ciphertext-v1"))
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/edit", token, map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext-v2")),
		"crypto_protocol": "mls10-openmls-v1",
	}); status != http.StatusOK {
		t.Fatalf("edit status=%d body=%s", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/delete", token, map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("encrypted delete marker")),
		"crypto_protocol": "mls10-openmls-v1",
	}); status != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", status, body)
	}
	frames := drainSyncAvailableFrames(t, client)
	if len(frames) != 3 {
		t.Fatalf("got %d sync.available frames, want 3 (created, edited, deleted)", len(frames))
	}
	var first []byte
	for i, raw := range frames {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			t.Fatalf("decode frame: %v", err)
		}
		if _, ok := fields["created_at"]; !ok {
			t.Fatalf("frame without created_at: %s", raw)
		}
		delete(fields, "created_at")
		if len(fields) != 2 || string(fields["version"]) != `"v1"` || string(fields["type"]) != `"sync.available"` {
			t.Fatalf("frame %d carries more than a sync.available event: %s", i, raw)
		}
		for _, leak := range [][]byte{[]byte(messageID), []byte(conversationID), []byte(base64.StdEncoding.EncodeToString([]byte("ciphertext-v2")))} {
			if bytes.Contains(raw, leak) {
				t.Fatalf("frame %d names the message: %s", i, raw)
			}
		}
		bare, _ := json.Marshal(fields)
		if first == nil {
			first = bare
		} else if !bytes.Equal(first, bare) {
			t.Fatalf("frames differ: %s and %s", first, bare)
		}
	}
}

// drainSyncAvailableFrames returns the sync.available frames queued for
// client.
func drainSyncAvailableFrames(t *testing.T, client *realtime.Client) [][]byte {
	t.Helper()
	var frames [][]byte
	deadline := time.After(50 * time.Millisecond)
	for {
		select {
		case raw := <-client.Send():
			var event struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(raw, &event); err != nil {
				t.Fatalf("decode realtime event: %v", err)
			}
			if event.Type == "sync.available" {
				frames = append(frames, raw)
			}
		case <-deadline:
			return frames
		}
	}
}
