package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"net/http"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

// C6 owner decision (2026-11-11, docs/designs/C6-reports-franking.md,
// "Private channels"): a report about a post in a private channel is offered
// only to the moderator keys of the channel's own members; the shared
// conversation keeps every community member's key. The subset check in
// CreateReport follows the same list.
func TestPrivateChannelReportsRouteOnlyToItsMembers(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.CommunityLayout = true })
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "pcreporter")
	modToken, modID := registerMemberWithID(t, handler, ownerToken, "pcmoderator")
	ownerID := accountIDFromExport(t, handler, ownerToken)

	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, body)
	}
	var community struct {
		ID                   string `json:"id"`
		SharedConversationID string `json:"shared_conversation_id"`
	}
	decodeLayoutBody(t, body, &community)
	if community.SharedConversationID == "" {
		t.Fatalf("community without a shared conversation: %s", body)
	}
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{"kind": "private"})
	if status != http.StatusCreated {
		t.Fatalf("create private channel status=%d body=%s", status, body)
	}
	var created struct {
		Channel layoutChannelJSON `json:"channel"`
	}
	decodeLayoutBody(t, body, &created)
	private := created.Channel.ConversationID
	if private == "" || private == community.SharedConversationID {
		t.Fatalf("private channel conversation = %q", private)
	}
	for id, role := range map[string]string{reporterID: "member", modID: "moderator"} {
		if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/members", ownerToken, map[string]interface{}{"account_id": id, "role": role}); status != http.StatusOK {
			t.Fatalf("add community member status=%d body=%s", status, body)
		}
	}
	// The reporter is in the private channel; the moderator is not.
	addMember(t, handler, ownerToken, private, reporterID)

	modKey := bytes.Repeat([]byte{3}, 32)
	ownerKey := bytes.Repeat([]byte{5}, 32)
	modInbox := community.ID + ":" + modID
	ownerInbox := community.ID + ":" + ownerID
	modCopy := reportCopy{InboxID: modInbox, Rev: 1, Key: modKey, Sealed: sealedWith(5)}
	ownerCopy := reportCopy{InboxID: ownerInbox, Rev: 1, Key: ownerKey, Sealed: sealedWith(6)}
	keyPath := "/api/v1/reports/inbox-keys/community/" + community.ID
	publish := func(name, token string, key []byte) {
		t.Helper()
		if status, body := doJSON(t, handler, http.MethodPut, keyPath, token, map[string]interface{}{"public_key": base64.StdEncoding.EncodeToString(key)}); status != http.StatusOK {
			t.Fatalf("%s publish status=%d body=%s", name, status, body)
		}
	}
	inbox := func(conversationID string) string {
		t.Helper()
		status, body := doJSON(t, handler, http.MethodGet, "/api/v1/reports/inbox?conversation_id="+conversationID, reporterToken, nil)
		if status != http.StatusOK && status != http.StatusConflict {
			t.Fatalf("inbox %s status=%d body=%s", conversationID, status, body)
		}
		return string(body)
	}

	// Only a moderator outside the channel has a key: the channel has no
	// inbox, and a copy to that moderator is refused.
	publish("moderator", modToken, modKey)
	if body := inbox(private); !strings.Contains(body, "report_inbox_unavailable") {
		t.Fatalf("private inbox with no member key = %s", body)
	}
	if status, body := fileReport(t, handler, reporterToken, private, reportIDOne, modCopy); status != http.StatusConflict || !strings.Contains(body, "report_inbox_unavailable") {
		t.Fatalf("report to a moderator outside the channel status=%d body=%s", status, body)
	}

	publish("owner", ownerToken, ownerKey)
	// The shared conversation is unchanged: every community member's key.
	if body := inbox(community.SharedConversationID); !strings.Contains(body, modInbox) || !strings.Contains(body, ownerInbox) {
		t.Fatalf("shared inbox = %s", body)
	}
	// The private channel lists only the owner, who created it.
	if body := inbox(private); strings.Contains(body, modInbox) || !strings.Contains(body, ownerInbox) {
		t.Fatalf("private inbox = %s", body)
	}
	if status, body := fileReport(t, handler, reporterToken, private, reportIDOne, ownerCopy, modCopy); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("report with a copy for a non-member status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, private, reportIDOne, ownerCopy); status != http.StatusCreated {
		t.Fatalf("report to the channel's moderators status=%d body=%s", status, body)
	}

	// Once the moderator joins the channel it is listed and accepted.
	addMember(t, handler, ownerToken, private, modID)
	if body := inbox(private); !strings.Contains(body, modInbox) || !strings.Contains(body, ownerInbox) {
		t.Fatalf("private inbox after the moderator joined = %s", body)
	}
	if status, body := fileReport(t, handler, reporterToken, private, "rpt-0000000000000002", modCopy); status != http.StatusCreated {
		t.Fatalf("report to a moderator in the channel status=%d body=%s", status, body)
	}
}
