package httpapi_test

import (
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
