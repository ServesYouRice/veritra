package httpapi_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"testing"
	"time"

	"private-messenger/server/internal/config"
)

type scopedSyncPage struct {
	Scope         string `json:"scope"`
	ScopeID       string `json:"scope_id"`
	Epoch         string `json:"sync_epoch"`
	OldestEventID int64  `json:"oldest_event_id"`
	LatestEventID int64  `json:"latest_event_id"`
	Events        []struct {
		ID             int64  `json:"id"`
		ConversationID string `json:"conversation_id"`
	} `json:"events"`
}

func getScopedSyncPage(t *testing.T, handler http.Handler, path, token string, wantStatus int) scopedSyncPage {
	t.Helper()
	status, body := doJSON(t, handler, http.MethodGet, path, token, nil)
	if status != wantStatus {
		t.Fatalf("GET %s status=%d want %d body=%s", path, status, wantStatus, body)
	}
	var page scopedSyncPage
	if err := json.Unmarshal(body, &page); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	return page
}

func TestScopedSyncRoutesAre404WhenSwitchedOff(t *testing.T) {
	_, handler, token, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.ScopedSync = false })
	conversationID := createConversation(t, handler, token)
	for _, path := range []string{
		"/api/v1/sync/account-events?after=0",
		"/api/v1/conversations/" + conversationID + "/sync-events?after=0",
	} {
		if status, body := doJSON(t, handler, http.MethodGet, path, token, nil); status != http.StatusNotFound {
			t.Fatalf("GET %s with the switch off: status=%d body=%s", path, status, body)
		}
	}
}

func TestScopedSyncRoutesRequireAuthAndMembership(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.ScopedSync = true })
	outsiderToken := registerMember(t, handler, ownerToken, "outsider")
	conversationID := createConversation(t, handler, ownerToken)
	for _, path := range []string{
		"/api/v1/sync/account-events?after=0",
		"/api/v1/conversations/" + conversationID + "/sync-events?after=0",
	} {
		if status, body := doJSON(t, handler, http.MethodGet, path, "", nil); status != http.StatusUnauthorized {
			t.Fatalf("GET %s without a token: status=%d body=%s", path, status, body)
		}
	}
	getScopedSyncPage(t, handler, "/api/v1/conversations/"+conversationID+"/sync-events?after=0", outsiderToken, http.StatusForbidden)
	getScopedSyncPage(t, handler, "/api/v1/conversations/conv_missing/sync-events?after=0", outsiderToken, http.StatusForbidden)
	// The outsider's own account stream still works and holds no conversation event.
	page := getScopedSyncPage(t, handler, "/api/v1/sync/account-events?after=0", outsiderToken, http.StatusOK)
	for _, e := range page.Events {
		if e.ConversationID != "" {
			t.Fatalf("account stream carried conversation event %d", e.ID)
		}
	}
}

func TestScopedSyncEnvelopeAndLegacyEquivalence(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.ScopedSync = true })
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "scopedmember")
	conversationID := createConversation(t, handler, ownerToken)
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{"account_id": memberID, "role": "member"}); status != http.StatusOK {
		t.Fatalf("add member status=%d body=%s", status, body)
	}
	createMessage(t, handler, ownerToken, conversationID, "scoped-1", []byte("ciphertext-1"))
	createMessage(t, handler, ownerToken, conversationID, "scoped-2", []byte("ciphertext-2"))

	for name, token := range map[string]string{"owner": ownerToken, "member": memberToken} {
		legacy := getScopedSyncPage(t, handler, "/api/v1/sync/events?after=0&limit=200", token, http.StatusOK)
		account := getScopedSyncPage(t, handler, "/api/v1/sync/account-events?after=0&limit=200", token, http.StatusOK)
		conversation := getScopedSyncPage(t, handler, "/api/v1/conversations/"+conversationID+"/sync-events?after=0&limit=200", token, http.StatusOK)

		if account.Scope != "account" || account.ScopeID == "" {
			t.Fatalf("%s account envelope scope=%q scope_id=%q", name, account.Scope, account.ScopeID)
		}
		if conversation.Scope != "conversation" || conversation.ScopeID != conversationID {
			t.Fatalf("%s conversation envelope scope=%q scope_id=%q", name, conversation.Scope, conversation.ScopeID)
		}
		for _, page := range []scopedSyncPage{account, conversation} {
			if page.Epoch == "" || page.Epoch != legacy.Epoch || page.OldestEventID != legacy.OldestEventID || page.LatestEventID != legacy.LatestEventID {
				t.Fatalf("%s bounds %+v differ from legacy %+v", name, page, legacy)
			}
		}
		var got, want []int64
		for _, e := range account.Events {
			if e.ConversationID != "" {
				t.Fatalf("%s account stream carried conversation event %d", name, e.ID)
			}
			got = append(got, e.ID)
		}
		for _, e := range conversation.Events {
			if e.ConversationID != conversationID {
				t.Fatalf("%s conversation stream carried event %d of %q", name, e.ID, e.ConversationID)
			}
			got = append(got, e.ID)
		}
		for _, e := range legacy.Events {
			want = append(want, e.ID)
		}
		sort.Slice(got, func(i, j int) bool { return got[i] < got[j] })
		if len(want) == 0 || len(got) != len(want) {
			t.Fatalf("%s scoped %v, legacy %v", name, got, want)
		}
		for i := range got {
			if got[i] != want[i] {
				t.Fatalf("%s scoped %v, legacy %v", name, got, want)
			}
		}
	}

	// A page past the end is an empty list, not null.
	_, body := doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+conversationID+"/sync-events?after=999999", ownerToken, nil)
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil || string(raw["events"]) != "[]" {
		t.Fatalf("empty page body=%s err=%v", body, err)
	}
}

// A conversation cursor behind that conversation's pruned events answers a
// scoped 409 (conversation_recovery_required, never the device-wide code),
// while the account stream at the same cursor keeps working.
func TestScopedSyncConversationExpiryIsScoped(t *testing.T) {
	application, handler, token, dbPath := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.ScopedSync = true })
	conversationID := createConversation(t, handler, token)
	createMessage(t, handler, token, conversationID, "scoped-expiry-seen", []byte("ciphertext"))
	first := getScopedSyncPage(t, handler, "/api/v1/conversations/"+conversationID+"/sync-events?after=0", token, http.StatusOK)
	if len(first.Events) == 0 {
		t.Fatal("no conversation event to hold a cursor on")
	}
	cursor := first.Events[len(first.Events)-1].ID
	for i := 0; i < 3; i++ {
		createMessage(t, handler, token, conversationID, "scoped-expiry-"+strconv.Itoa(i), []byte("ciphertext"))
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	var latest int64
	if err := db.QueryRow(`SELECT MAX(id) FROM sync_events WHERE conversation_id = ?`, conversationID).Scan(&latest); err != nil {
		t.Fatalf("latest event: %v", err)
	}
	if _, err := db.Exec(`UPDATE sync_events SET created_at = '2000-01-01T00:00:00.000000000Z' WHERE id > ? AND id < ? AND conversation_id = ?`, cursor, latest, conversationID); err != nil {
		t.Fatalf("age events: %v", err)
	}
	if _, err := application.Store.PruneSyncEvents(context.Background(), time.Now().UTC().Add(-time.Hour)); err != nil {
		t.Fatalf("prune: %v", err)
	}

	path := "/api/v1/conversations/" + conversationID + "/sync-events?after=" + strconv.FormatInt(cursor, 10)
	status, body := doJSON(t, handler, http.MethodGet, path, token, nil)
	if status != http.StatusConflict {
		t.Fatalf("expired conversation cursor status=%d body=%s", status, body)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatalf("decode 409: %v", err)
	}
	if string(raw["error"]) != `"conversation_recovery_required"` || string(raw["scope"]) != `"conversation"` || string(raw["scope_id"]) != strconv.Quote(conversationID) {
		t.Fatalf("scoped 409 body=%s", body)
	}
	if _, ok := raw["events"]; ok {
		t.Fatalf("409 carries events: %s", body)
	}
	for _, key := range []string{"sync_epoch", "oldest_event_id", "latest_event_id"} {
		if _, ok := raw[key]; !ok {
			t.Fatalf("409 lacks %s: %s", key, body)
		}
	}
	getScopedSyncPage(t, handler, "/api/v1/sync/account-events?after="+strconv.FormatInt(cursor, 10), token, http.StatusOK)
}

// A client pauses one conversation only after it has read the failed event
// back with after=<id-1>&limit=1 (C1 prerequisite 1, mobile
// AppState._pauseConversationAt). The probe must return exactly that event
// for every event the stream serves, including the first event a member can
// see, with hidden rows below it, and must echo the requested scope.
func TestScopedSyncProbeReturnsExactlyTheNamedEvent(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, func(c *config.Config) { c.ScopedSync = true })
	conversationID := createConversation(t, handler, ownerToken)
	createMessage(t, handler, ownerToken, conversationID, "probe-before-join", []byte("ciphertext-0"))
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "probemember")
	if status, body := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{"account_id": memberID, "role": "member"}); status != http.StatusOK {
		t.Fatalf("add member status=%d body=%s", status, body)
	}
	for i := 1; i <= 3; i++ {
		createMessage(t, handler, ownerToken, conversationID, "probe-"+strconv.Itoa(i), []byte("ciphertext-"+strconv.Itoa(i)))
	}
	base := "/api/v1/conversations/" + conversationID + "/sync-events"
	for name, token := range map[string]string{"owner": ownerToken, "member": memberToken} {
		all := getScopedSyncPage(t, handler, base+"?after=0&limit=200", token, http.StatusOK)
		if len(all.Events) < 3 {
			t.Fatalf("%s sees %d events, want at least 3", name, len(all.Events))
		}
		for _, e := range all.Events {
			probe := getScopedSyncPage(t, handler, base+"?after="+strconv.FormatInt(e.ID-1, 10)+"&limit=1", token, http.StatusOK)
			if probe.Scope != "conversation" || probe.ScopeID != conversationID {
				t.Fatalf("%s probe envelope scope=%q scope_id=%q", name, probe.Scope, probe.ScopeID)
			}
			if len(probe.Events) != 1 || probe.Events[0].ID != e.ID || probe.Events[0].ConversationID != conversationID {
				t.Fatalf("%s probe for event %d returned %+v", name, e.ID, probe.Events)
			}
		}
	}
}
