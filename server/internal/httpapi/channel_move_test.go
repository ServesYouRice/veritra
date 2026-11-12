package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"private-messenger/server/internal/config"
)

// C3 channel conversion over HTTP: owner or admin only, the answer names
// the new conversation, both conversations' members get the stored
// ids-only event live, and the moved-history routes are not found while
// C7 is off.
func TestChannelMoveRoute(t *testing.T) {
	for _, c7 := range []bool{false, true} {
		application, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) {
			c.CommunityLayout = true
			c.C7History = c7
		})
		ownerID := accountIDFromExport(t, handler, ownerToken)
		carolToken, carolID := registerMemberWithID(t, handler, ownerToken, "carol")
		status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
		if status != http.StatusCreated {
			t.Fatalf("create community status=%d body=%s", status, body)
		}
		var community struct {
			ID                   string `json:"id"`
			SharedConversationID string `json:"shared_conversation_id"`
		}
		decodeLayoutBody(t, body, &community)
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/members", ownerToken, map[string]interface{}{"account_id": carolID, "role": "member"}); status != http.StatusOK {
			t.Fatalf("add member status=%d body=%s", status, body)
		}
		status, body = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{"kind": "open"})
		if status != http.StatusCreated {
			t.Fatalf("create channel status=%d body=%s", status, body)
		}
		var created struct {
			Channel struct {
				ID string `json:"id"`
			} `json:"channel"`
		}
		decodeLayoutBody(t, body, &created)
		channel := created.Channel.ID
		carolLive, err := application.Hub.Register(carolID, "dev-carol", "10.0.0.2")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(carolLive.Close)
		ownerLive, err := application.Hub.Register(ownerID, "dev-owner", "10.0.0.1")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(ownerLive.Close)

		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/channels/"+channel+"/move", carolToken, map[string]interface{}{"access_mode": "private"}); status != http.StatusForbidden {
			t.Fatalf("member move status=%d body=%s", status, body)
		}
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/channels/"+channel+"/move", ownerToken, map[string]interface{}{"access_mode": "announcement"}); status != http.StatusBadRequest {
			t.Fatalf("same-kind move status=%d body=%s", status, body)
		}
		status, body = doJSON(t, handler, http.MethodPost, "/api/v1/channels/"+channel+"/move", ownerToken, map[string]interface{}{"access_mode": "private"})
		if status != http.StatusOK {
			t.Fatalf("move status=%d body=%s", status, body)
		}
		var moved struct {
			Move struct {
				From string `json:"from_conversation_id"`
				To   string `json:"to_conversation_id"`
			} `json:"move"`
			Conversation struct {
				ID string `json:"id"`
			} `json:"conversation"`
		}
		decodeLayoutBody(t, body, &moved)
		if moved.Move.From != community.SharedConversationID || moved.Move.To == "" || moved.Conversation.ID != moved.Move.To {
			t.Fatalf("move answer = %s", body)
		}
		// Carol, in the shared conversation only, hears of it there; the
		// owner in both. The event names who moved it (review L-6).
		frames := func(client interface{ Send() <-chan []byte }) int {
			got := 0
			deadline := time.After(50 * time.Millisecond)
			for {
				select {
				case raw := <-client.Send():
					var event struct {
						Type    string `json:"type"`
						Payload struct {
							MovedBy string `json:"moved_by"`
						} `json:"payload"`
					}
					if json.Unmarshal(raw, &event) == nil && event.Type == "conversation.channel_moved" {
						if event.Payload.MovedBy != ownerID {
							t.Fatalf("c7=%v: moved frame names %q, want %q", c7, event.Payload.MovedBy, ownerID)
						}
						got++
					}
				case <-deadline:
					return got
				}
			}
		}
		for client, want := range map[interface{ Send() <-chan []byte }]int{carolLive: 1, ownerLive: 2} {
			if got := frames(client); got != want {
				t.Fatalf("c7=%v: %d moved frames, want %d", c7, got, want)
			}
		}
		// A replay (review L-6) answers the same move and publishes nothing.
		status, replayed := doJSON(t, handler, http.MethodPost, "/api/v1/channels/"+channel+"/move", ownerToken, map[string]interface{}{"access_mode": "private"})
		if status != http.StatusOK {
			t.Fatalf("replay status=%d body=%s", status, replayed)
		}
		var again struct {
			Move struct {
				To      string `json:"to_conversation_id"`
				MovedBy string `json:"moved_by"`
			} `json:"move"`
		}
		decodeLayoutBody(t, replayed, &again)
		if again.Move.To != moved.Move.To || again.Move.MovedBy != ownerID {
			t.Fatalf("replay answer = %s", replayed)
		}
		if got := frames(ownerLive); got != 0 {
			t.Fatalf("c7=%v: a replay published %d moved frames", c7, got)
		}
		history := "/api/v1/channels/" + channel + "/moves/" + community.SharedConversationID + "/history?stream=" + channel
		status, body = doJSON(t, handler, http.MethodGet, history, ownerToken, nil)
		if !c7 && status != http.StatusNotFound {
			t.Fatalf("c7 off: moved history status=%d body=%s", status, body)
		}
		// On, the owner is a member of the new conversation but has no
		// group there yet.
		if c7 && status != http.StatusForbidden {
			t.Fatalf("c7 on, no group: moved history status=%d body=%s", status, body)
		}
	}
}
