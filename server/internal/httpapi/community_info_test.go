package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"

	"private-messenger/server/internal/config"
)

// C3 routes (docs/designs/C3-private-channels-and-info.md): community,
// category and channel records. Unreadable is 404, never 403; a reader who
// may not write gets 403.
func TestCommunityInfoRoutes(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.CommunityLayout = true })
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "infomember")
	strangerToken, _ := registerMemberWithID(t, handler, ownerToken, "infostranger")

	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{"name": "Club"})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, body)
	}
	var community struct {
		ID string `json:"id"`
	}
	decodeLayoutBody(t, body, &community)
	channelPath := "/api/v1/communities/" + community.ID + "/channels"
	channel := func(kind string) string {
		status, body := doJSON(t, handler, http.MethodPost, channelPath, ownerToken, map[string]interface{}{"name": "c", "kind": kind})
		if status != http.StatusCreated {
			t.Fatalf("create %q channel status=%d body=%s", kind, status, body)
		}
		var created struct {
			Channel layoutChannelJSON `json:"channel"`
		}
		decodeLayoutBody(t, body, &created)
		return created.Channel.ID
	}
	open, private := channel(""), channel("private")
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/members", ownerToken, map[string]interface{}{"account_id": memberID, "role": "member"}); status != http.StatusOK {
		t.Fatalf("add member status=%d body=%s", status, body)
	}

	communityPath := "/api/v1/communities/" + community.ID + "/info"
	categoryPath := "/api/v1/communities/" + community.ID + "/categories/cat_0123456789abcdef0123456789abcdef"
	openPath := "/api/v1/channels/" + open + "/info"
	privatePath := "/api/v1/channels/" + private + "/info"
	blob := profileBlob(testProfileSmall, 3)

	// Community: owner writes, member is refused with 403, stranger with 404.
	if status, body := profilePut(t, handler, communityPath, memberToken, blob, testProfileKeyA, "*"); status != http.StatusForbidden {
		t.Fatalf("member community put = %d %s", status, body)
	}
	if status, body := profilePut(t, handler, communityPath, strangerToken, blob, testProfileKeyA, "*"); status != http.StatusNotFound {
		t.Fatalf("stranger community put = %d %s", status, body)
	}
	if status, body := profilePut(t, handler, communityPath, ownerToken, blob, testProfileKeyA, "*"); status != http.StatusOK {
		t.Fatalf("owner community put = %d %s", status, body)
	}
	rec := profileGet(t, handler, communityPath, memberToken, nil)
	if rec.Code != http.StatusOK || rec.Header().Get("ETag") != `"1"` || rec.Header().Get("X-Profile-Key-Id") != testProfileKeyA || rec.Body.Len() != testProfileSmall {
		t.Fatalf("member community get = %d etag=%q", rec.Code, rec.Header().Get("ETag"))
	}
	if rec := profileGet(t, handler, communityPath, strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger community get = %d", rec.Code)
	}
	// A wrong-size body is refused before storage.
	if status, _ := profilePut(t, handler, communityPath, ownerToken, profileBlob(100, 3), testProfileKeyA, `"1"`); status != http.StatusBadRequest {
		t.Fatalf("bad size put = %d", status)
	}

	// Category: bound by the first owner write; a member reads it.
	if status, body := profilePut(t, handler, categoryPath, memberToken, blob, testProfileKeyA, "*"); status != http.StatusForbidden {
		t.Fatalf("member category put = %d %s", status, body)
	}
	if status, body := profilePut(t, handler, categoryPath, ownerToken, profileBlob(testProfileLarge, 4), testProfileKeyA, "*"); status != http.StatusOK {
		t.Fatalf("owner category put = %d %s", status, body)
	}
	if rec := profileGet(t, handler, categoryPath, memberToken, nil); rec.Code != http.StatusOK || rec.Body.Len() != testProfileLarge {
		t.Fatalf("member category get = %d", rec.Code)
	}
	if rec := profileGet(t, handler, categoryPath, strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger category get = %d", rec.Code)
	}

	// Channels: any member edits an open channel (D80); a private one is
	// invisible to non-members, as 404.
	if status, body := profilePut(t, handler, openPath, memberToken, blob, testProfileKeyB, "*"); status != http.StatusOK {
		t.Fatalf("member open put = %d %s", status, body)
	}
	if status, body := profilePut(t, handler, privatePath, ownerToken, blob, testProfileKeyB, "*"); status != http.StatusOK {
		t.Fatalf("owner private put = %d %s", status, body)
	}
	if rec := profileGet(t, handler, privatePath, memberToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("non-member private get = %d", rec.Code)
	}
	if status, _ := profilePut(t, handler, privatePath, memberToken, blob, testProfileKeyB, `"1"`); status != http.StatusNotFound {
		t.Fatalf("non-member private put = %d", status)
	}

	// Versions: the member sees the community, the category and the open
	// channel, never the private one.
	status, body = doJSON(t, handler, http.MethodPost, "/api/v1/profiles/versions", memberToken, map[string]interface{}{
		"community_ids": []string{community.ID},
		"category_ids":  []string{"cat_0123456789abcdef0123456789abcdef"},
		"channel_ids":   []string{open, private},
	})
	if status != http.StatusOK {
		t.Fatalf("versions status=%d body=%s", status, body)
	}
	var versions struct {
		Versions []struct {
			Kind string `json:"kind"`
			ID   string `json:"id"`
		} `json:"versions"`
	}
	if err := json.Unmarshal(body, &versions); err != nil {
		t.Fatal(err)
	}
	if len(versions.Versions) != 3 {
		t.Fatalf("member versions = %s", body)
	}
	for _, v := range versions.Versions {
		if v.ID == private {
			t.Fatalf("private channel leaked in versions: %s", body)
		}
	}

	// The member's sync carries info.updated with IDs only, and nothing for
	// the private channel.
	status, body = doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=200", memberToken, nil)
	if status != http.StatusOK {
		t.Fatalf("sync status=%d", status)
	}
	var events struct {
		Events []struct {
			Type    string                 `json:"type"`
			Payload map[string]interface{} `json:"payload"`
		} `json:"events"`
	}
	if err := json.Unmarshal(body, &events); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, e := range events.Events {
		if e.Type != "info.updated" {
			continue
		}
		if len(e.Payload) != 4 || e.Payload["key_id"] == nil || e.Payload["version"] == nil {
			t.Fatalf("info.updated payload = %v", e.Payload)
		}
		seen[e.Payload["subject_kind"].(string)+":"+e.Payload["subject_id"].(string)] = true
	}
	if !seen["community:"+community.ID] || !seen["channel:"+open] || seen["channel:"+private] {
		t.Fatalf("member info events = %v", seen)
	}
}
