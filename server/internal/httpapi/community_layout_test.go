package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"

	"private-messenger/server/internal/config"
)

type layoutChannelJSON struct {
	ID               string `json:"id"`
	Kind             string `json:"kind"`
	ConversationID   string `json:"conversation_id"`
	LayoutVersion    int    `json:"layout_version"`
	LayoutGeneration int    `json:"layout_generation"`
}

func decodeLayoutBody(t *testing.T, body []byte, into interface{}) {
	t.Helper()
	if err := json.Unmarshal(body, into); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
}

func TestCommunityLayoutHTTPRoutesPostsThroughTheSharedGroup(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.CommunityLayout = true })
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "layoutmember")

	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, body)
	}
	var community struct {
		ID                   string `json:"id"`
		LayoutVersion        int    `json:"layout_version"`
		SharedConversationID string `json:"shared_conversation_id"`
	}
	decodeLayoutBody(t, body, &community)
	if community.LayoutVersion != 1 || community.SharedConversationID == "" {
		t.Fatalf("community = %s", body)
	}
	channelPath := "/api/v1/communities/" + community.ID + "/channels"
	create := func(kind string) (layoutChannelJSON, string) {
		status, body := doJSON(t, handler, http.MethodPost, channelPath, ownerToken, map[string]interface{}{"kind": kind})
		if status != http.StatusCreated {
			t.Fatalf("create %q channel status=%d body=%s", kind, status, body)
		}
		var created struct {
			Channel      layoutChannelJSON `json:"channel"`
			Conversation struct {
				ID        string  `json:"id"`
				Kind      string  `json:"kind"`
				ChannelID *string `json:"channel_id"`
			} `json:"conversation"`
		}
		decodeLayoutBody(t, body, &created)
		if created.Channel.ConversationID != created.Conversation.ID {
			t.Fatalf("channel route and conversation differ: %s", body)
		}
		if kind != "private" && (created.Conversation.Kind != "community_shared" || created.Conversation.ChannelID != nil) {
			t.Fatalf("shared conversation = %s", body)
		}
		return created.Channel, created.Conversation.ID
	}
	open, openConversation := create("")
	announcement, _ := create("announcement")
	private, privateConversation := create("private")
	if open.Kind != "open" || openConversation != community.SharedConversationID || private.ConversationID == community.SharedConversationID || privateConversation == openConversation {
		t.Fatalf("routes: open=%+v announcement=%+v private=%+v", open, announcement, private)
	}
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/members", ownerToken, map[string]interface{}{"account_id": memberID, "role": "member"}); status != http.StatusOK {
		t.Fatalf("add member status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodGet, channelPath, memberToken, nil)
	var listed struct {
		Channels []layoutChannelJSON `json:"channels"`
	}
	decodeLayoutBody(t, body, &listed)
	if status != http.StatusOK || len(listed.Channels) != 2 {
		t.Fatalf("member channel list status=%d body=%s, want the private channel hidden", status, body)
	}

	send := func(token, key string, metadata map[string]interface{}) (int, []byte) {
		payload := map[string]interface{}{
			"conversation_id": community.SharedConversationID,
			"idempotency_key": key,
			"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext")),
			"crypto_protocol": "mls10-openmls-v1",
		}
		if metadata != nil {
			payload["crypto_metadata"] = metadata
		}
		return doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, payload)
	}
	route := func(channelID string) map[string]interface{} {
		return map[string]interface{}{"channel_id": channelID, "community_layout_generation": 1, "mls_epoch": 1}
	}
	if status, body := send(memberToken, "ok", route(open.ID)); status != http.StatusCreated {
		t.Fatalf("post in the open channel status=%d body=%s", status, body)
	}
	for name, metadata := range map[string]map[string]interface{}{
		"no context":      nil,
		"private channel": route(private.ID),
		"unknown channel": route("chan_missing"),
		"stale":           {"channel_id": open.ID, "community_layout_generation": 2},
	} {
		status, body := send(memberToken, "bad-"+name, metadata)
		if status != http.StatusBadRequest || !bytes.Contains(body, []byte("invalid_crypto_metadata")) {
			t.Errorf("%s: status=%d body=%s, want 400 invalid_crypto_metadata", name, status, body)
		}
	}
	if status, body := send(memberToken, "announce", route(announcement.ID)); status != http.StatusForbidden || !bytes.Contains(body, []byte("posting_restricted")) {
		t.Fatalf("member post in announcement channel status=%d body=%s", status, body)
	}
	if status, body := send(ownerToken, "announce-owner", route(announcement.ID)); status != http.StatusCreated {
		t.Fatalf("owner post in announcement channel status=%d body=%s", status, body)
	}
	// A new community cannot be given a conversation by hand.
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind": "community_channel", "community_id": community.ID, "channel_id": open.ID,
	}); status != http.StatusForbidden {
		t.Fatalf("hand-made community conversation status=%d body=%s", status, body)
	}
}

// The switch is on by default (config.Load); switched off, new communities
// keep the legacy one-conversation-per-channel layout.
func TestCommunityLayoutSwitchedOffKeepsTheLegacyLayout(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.CommunityLayout = false })
	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, body)
	}
	var community struct {
		ID                   string `json:"id"`
		SharedConversationID string `json:"shared_conversation_id"`
	}
	decodeLayoutBody(t, body, &community)
	if community.SharedConversationID != "" {
		t.Fatalf("legacy community advertises a shared conversation: %s", body)
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{"kind": "open"})
	if status != http.StatusBadRequest {
		t.Fatalf("open channel in a legacy community status=%d body=%s", status, body)
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated || !bytes.Contains(body, []byte(`"kind":"community_channel"`)) {
		t.Fatalf("legacy channel status=%d body=%s", status, body)
	}
}
