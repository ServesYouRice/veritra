package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"net/http"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

// C7 step 3 (docs/designs/C7-channel-history.md): with
// PRIVATE_MESSENGER_C7_HISTORY off (the default) nothing new answers, a
// sealed body is refused and the setup status says nothing; on, the status
// says c7_history and a community send without a body is refused.
func TestC7HistoryRoutesFollowTheSwitch(t *testing.T) {
	for _, on := range []bool{false, true} {
		_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) {
			c.CommunityLayout = true
			c.C7History = on
		})
		status, body := doJSON(t, handler, http.MethodGet, "/api/v1/setup/status", "", nil)
		if status != http.StatusOK || strings.Contains(string(body), "c7_history") != on {
			t.Fatalf("c7=%v setup status=%d body=%s", on, status, body)
		}
		status, body = doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
		if status != http.StatusCreated {
			t.Fatalf("create community status=%d body=%s", status, body)
		}
		var community struct {
			SharedConversationID string `json:"shared_conversation_id"`
		}
		decodeLayoutBody(t, body, &community)
		shared := community.SharedConversationID
		if shared == "" {
			t.Fatalf("community has no shared group: %s", body)
		}
		history := "/api/v1/conversations/" + shared + "/history"
		keys := "/api/v1/conversations/" + shared + "/former-member-keys"
		hide := "/api/v1/messages/msg_missing/history-hide"
		if !on {
			for _, path := range []string{history, keys} {
				if status, body := doJSON(t, handler, http.MethodGet, path, ownerToken, nil); status != http.StatusNotFound {
					t.Fatalf("c7 off: GET %s = %d %s", path, status, body)
				}
			}
			if status, body := doJSON(t, handler, http.MethodPost, hide, ownerToken, map[string]interface{}{}); status != http.StatusNotFound {
				t.Fatalf("c7 off: history-hide = %d %s", status, body)
			}
			continue
		}
		// On: a missing message is not found, not an error.
		if status, body := doJSON(t, handler, http.MethodPost, hide, ownerToken, map[string]interface{}{}); status != http.StatusNotFound {
			t.Fatalf("c7 on: history-hide of a missing message = %d %s", status, body)
		}
	}
}

// C7 on, over HTTP: the sealed_body field, its size rule, the single-message
// GET without a body, the 409 on legacy paging, and the history routes'
// answers for a device outside the group's roster.
func TestC7HistoryHTTPSealedBodyAndRoutes(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) {
		c.CommunityLayout = true
		c.C7History = true
	})
	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, body)
	}
	var community struct {
		ID                   string `json:"id"`
		SharedConversationID string `json:"shared_conversation_id"`
	}
	decodeLayoutBody(t, body, &community)
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{"kind": ""})
	if status != http.StatusCreated {
		t.Fatalf("create channel status=%d body=%s", status, body)
	}
	var created struct {
		Channel layoutChannelJSON `json:"channel"`
	}
	decodeLayoutBody(t, body, &created)
	send := func(key string, sealed []byte) (int, []byte) {
		payload := map[string]interface{}{
			"conversation_id": community.SharedConversationID,
			"idempotency_key": key,
			"ciphertext":      base64.StdEncoding.EncodeToString([]byte("reference")),
			"crypto_protocol": "mls10-openmls-v1",
			"crypto_metadata": map[string]interface{}{"channel_id": created.Channel.ID, "community_layout_generation": 1, "mls_epoch": 1},
		}
		if sealed != nil {
			payload["sealed_body"] = base64.StdEncoding.EncodeToString(sealed)
		}
		return doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", ownerToken, payload)
	}
	if status, body := send("odd", bytes.Repeat([]byte{1}, 381)); status != http.StatusBadRequest || !strings.Contains(string(body), "invalid_sealed_body") {
		t.Fatalf("odd-sized body status=%d body=%s", status, body)
	}
	status, body = send("ok", bytes.Repeat([]byte{2}, 380))
	if status != http.StatusCreated {
		t.Fatalf("send with body status=%d body=%s", status, body)
	}
	var envelope struct {
		ID string `json:"id"`
	}
	decodeLayoutBody(t, body, &envelope)
	if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+envelope.ID, ownerToken, nil); status != http.StatusOK || strings.Contains(string(body), "sealed_body") {
		t.Fatalf("single-message GET status=%d body=%s, want no body served", status, body)
	}
	if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+community.SharedConversationID+"/messages", ownerToken, nil); status != http.StatusConflict || !strings.Contains(string(body), "history_route_only") {
		t.Fatalf("legacy paging status=%d body=%s", status, body)
	}
	// The owner's device is not in this group's MLS roster (no commit has
	// run here): the history routes refuse it.
	for _, path := range []string{"/history?channel_id=" + created.Channel.ID, "/former-member-keys"} {
		if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+community.SharedConversationID+path, ownerToken, nil); status != http.StatusForbidden {
			t.Fatalf("GET %s status=%d body=%s", path, status, body)
		}
	}
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+envelope.ID+"/history-hide", ownerToken, map[string]interface{}{}); status != http.StatusOK || !strings.Contains(string(body), "history_hidden") {
		t.Fatalf("own history-hide status=%d body=%s", status, body)
	}
}
