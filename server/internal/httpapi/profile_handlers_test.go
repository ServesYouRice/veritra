package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

const (
	testProfileSmall = 4*1024 + 28
	testProfileLarge = 256*1024 + 28
	testProfileKeyA  = "5a7f7bb0d6bff19bebf7bfc3f05a9ed5"
	testProfileKeyB  = "0123456789abcdef0123456789abcdef"
)

func profileBlob(size int, fill byte) []byte {
	b := bytes.Repeat([]byte{fill}, size)
	copy(b, "VPE1")
	return b
}

func profilePut(t *testing.T, handler http.Handler, path, token string, body []byte, keyID, ifMatch string) (int, []byte) {
	t.Helper()
	headers := map[string]string{"X-Private-Messenger-Encrypted": "1", "X-Profile-Key-Id": keyID}
	if ifMatch == "*" {
		headers["If-None-Match"] = "*"
	} else if ifMatch != "" {
		headers["If-Match"] = ifMatch
	}
	return doRaw(t, handler, http.MethodPut, path, token, body, headers)
}

func profileGet(t *testing.T, handler http.Handler, path, token string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

func profileEvents(t *testing.T, handler http.Handler, token string) []map[string]interface{} {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=200", token, nil)
	if status != http.StatusOK {
		t.Fatalf("sync status=%d body=%s", status, response)
	}
	var decoded struct {
		Events []struct {
			Type    string                 `json:"type"`
			Payload map[string]interface{} `json:"payload"`
		} `json:"events"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	var out []map[string]interface{}
	for _, e := range decoded.Events {
		if e.Type == "profile.updated" {
			out = append(out, e.Payload)
		}
	}
	return out
}

// W11: read rule, versions, size buckets and events for account profiles.
func TestAccountProfileReadRuleVersionsAndEvents(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	bobToken, bobID := registerMemberWithID(t, handler, ownerToken, "profbob")
	strangerToken, _ := registerMemberWithID(t, handler, ownerToken, "profstranger")
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{"kind": "group", "member_account_ids": []string{bobID}})
	if status != http.StatusCreated {
		t.Fatalf("create group status=%d body=%s", status, response)
	}
	mine := "/api/v1/profiles/account/me"
	theirs := "/api/v1/profiles/account/" + ownerID

	// Nothing stored: 404 for everyone, the owner included.
	if rec := profileGet(t, handler, theirs, bobToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("empty get = %d", rec.Code)
	}
	// Header and shape checks.
	if status, _ = doRaw(t, handler, http.MethodPut, mine, ownerToken, profileBlob(testProfileSmall, 1), map[string]string{"X-Profile-Key-Id": testProfileKeyA, "If-None-Match": "*"}); status != http.StatusBadRequest {
		t.Fatalf("missing encrypted header = %d", status)
	}
	for name, c := range map[string]struct {
		body  []byte
		key   string
		match string
		want  int
	}{
		"bad key id":       {profileBlob(testProfileSmall, 1), "ZZ", "*", http.StatusBadRequest},
		"upper key id":     {profileBlob(testProfileSmall, 1), "5A7F7BB0D6BFF19BEBF7BFC3F05A9ED5", "*", http.StatusBadRequest},
		"odd size":         {profileBlob(5000, 1), testProfileKeyA, "*", http.StatusBadRequest},
		"bad magic":        {bytes.Repeat([]byte{9}, testProfileSmall), testProfileKeyA, "*", http.StatusBadRequest},
		"too large":        {profileBlob(testProfileLarge+1, 1), testProfileKeyA, "*", http.StatusRequestEntityTooLarge},
		"no precondition":  {profileBlob(testProfileSmall, 1), testProfileKeyA, "", http.StatusBadRequest},
		"first with match": {profileBlob(testProfileSmall, 1), testProfileKeyA, `"1"`, http.StatusPreconditionFailed},
	} {
		if status, response := profilePut(t, handler, mine, ownerToken, c.body, c.key, c.match); status != c.want {
			t.Fatalf("%s: status=%d body=%s want %d", name, status, response, c.want)
		}
	}
	// First write, then the stale first write conflicts.
	blob1 := profileBlob(testProfileSmall, 1)
	if status, response = profilePut(t, handler, mine, ownerToken, blob1, testProfileKeyA, "*"); status != http.StatusOK || !bytes.Contains(response, []byte(`"version":1`)) {
		t.Fatalf("first put status=%d body=%s", status, response)
	}
	if status, _ = profilePut(t, handler, mine, ownerToken, blob1, testProfileKeyA, "*"); status != http.StatusPreconditionFailed {
		t.Fatalf("repeat first put = %d", status)
	}
	blob2 := profileBlob(testProfileLarge, 2)
	if status, response = profilePut(t, handler, mine, ownerToken, blob2, testProfileKeyB, `"1"`); status != http.StatusOK || !bytes.Contains(response, []byte(`"version":2`)) {
		t.Fatalf("second put status=%d body=%s", status, response)
	}
	if status, _ = profilePut(t, handler, mine, ownerToken, blob2, testProfileKeyB, `"1"`); status != http.StatusPreconditionFailed {
		t.Fatalf("stale put = %d", status)
	}
	// Nobody else writes an account record: the route is always "me".
	if status, _ = profilePut(t, handler, "/api/v1/profiles/account/"+bobID, ownerToken, blob1, testProfileKeyA, "*"); status != http.StatusNotFound && status != http.StatusMethodNotAllowed {
		t.Fatalf("write to other account = %d", status)
	}

	// Co-member reads the exact bytes, with ETag and key id; a stranger gets 404.
	rec := profileGet(t, handler, theirs, bobToken, nil)
	if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), blob2) || rec.Header().Get("ETag") != `"2"` || rec.Header().Get("X-Profile-Key-Id") != testProfileKeyB {
		t.Fatalf("co-member get = %d etag=%q key=%q", rec.Code, rec.Header().Get("ETag"), rec.Header().Get("X-Profile-Key-Id"))
	}
	if rec = profileGet(t, handler, theirs, bobToken, map[string]string{"If-None-Match": `"2"`}); rec.Code != http.StatusNotModified {
		t.Fatalf("conditional get = %d", rec.Code)
	}
	if rec = profileGet(t, handler, theirs, strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger get = %d", rec.Code)
	}
	if rec = profileGet(t, handler, theirs, ownerToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("owner get = %d", rec.Code)
	}

	// profile.updated reaches the co-member and the owner, never the stranger,
	// and carries IDs and versions only.
	for name, token := range map[string]string{"bob": bobToken, "owner": ownerToken} {
		events := profileEvents(t, handler, token)
		if len(events) != 2 || events[1]["version"] != float64(2) || events[1]["key_id"] != testProfileKeyB || events[1]["subject_id"] != ownerID || events[1]["subject_kind"] != "account" || len(events[1]) != 4 {
			t.Fatalf("%s events = %v", name, events)
		}
	}
	if events := profileEvents(t, handler, strangerToken); len(events) != 0 {
		t.Fatalf("stranger events = %v", events)
	}

	// Batch versions leave out what the caller may not read.
	req := map[string]interface{}{"account_ids": []string{ownerID, bobID, "acct_zzzz"}}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/profiles/versions", bobToken, req)
	if status != http.StatusOK || !bytes.Contains(response, []byte(ownerID)) || bytes.Contains(response, []byte(bobID)) {
		t.Fatalf("versions status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/profiles/versions", strangerToken, req)
	if status != http.StatusOK || bytes.Contains(response, []byte(ownerID)) {
		t.Fatalf("stranger versions status=%d body=%s", status, response)
	}
	tooMany := make([]string, 201)
	if status, _ = doJSON(t, handler, http.MethodPost, "/api/v1/profiles/versions", bobToken, map[string]interface{}{"account_ids": tooMany}); status != http.StatusBadRequest {
		t.Fatalf("201 ids = %d", status)
	}

	// A block hides the record in both directions.
	if status, response = doJSON(t, handler, http.MethodPut, "/api/v1/account/blocks/"+ownerID, bobToken, nil); status >= 300 {
		t.Fatalf("block status=%d body=%s", status, response)
	}
	if rec = profileGet(t, handler, theirs, bobToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("blocker get = %d", rec.Code)
	}
	if rec = profileGet(t, handler, theirs, ownerToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("owner get after block = %d", rec.Code)
	}
	// A write after the block reaches the owner's devices but not Bob.
	if status, _ = profilePut(t, handler, mine, ownerToken, blob1, testProfileKeyA, `"2"`); status != http.StatusOK {
		t.Fatalf("put after block = %d", status)
	}
	if events := profileEvents(t, handler, bobToken); len(events) != 2 {
		t.Fatalf("blocker saw event after block: %v", events)
	}
	if status, _ = doJSON(t, handler, http.MethodDelete, "/api/v1/account/blocks/"+ownerID, bobToken, nil); status >= 300 {
		t.Fatalf("unblock = %d", status)
	}
	if rec = profileGet(t, handler, theirs, bobToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("get after unblock = %d", rec.Code)
	}
}

// W11: group records: any current member writes, others read as missing.
func TestGroupProfileMembersOnlyAndTitleClear(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	bobToken, bobID := registerMemberWithID(t, handler, ownerToken, "grpbob")
	strangerToken, _ := registerMemberWithID(t, handler, ownerToken, "grpstranger")
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{"kind": "group", "title": "Old plaintext", "member_account_ids": []string{bobID}})
	if status != http.StatusCreated {
		t.Fatalf("create group status=%d body=%s", status, response)
	}
	var group struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(response, &group)
	path := "/api/v1/conversations/" + group.ID + "/profile"
	blob := profileBlob(testProfileSmall, 7)

	if status, _ = profilePut(t, handler, path, strangerToken, blob, testProfileKeyA, "*"); status != http.StatusNotFound {
		t.Fatalf("stranger put = %d", status)
	}
	if status, response = profilePut(t, handler, path, bobToken, blob, testProfileKeyA, "*"); status != http.StatusOK {
		t.Fatalf("member put status=%d body=%s", status, response)
	}
	if rec := profileGet(t, handler, path, ownerToken, nil); rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), blob) {
		t.Fatalf("owner get = %d", rec.Code)
	}
	if rec := profileGet(t, handler, path, strangerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger get = %d", rec.Code)
	}
	if events := profileEvents(t, handler, ownerToken); len(events) != 1 || events[0]["subject_kind"] != "conversation" || events[0]["subject_id"] != group.ID {
		t.Fatalf("owner events = %v", events)
	}
	if events := profileEvents(t, handler, strangerToken); len(events) != 0 {
		t.Fatalf("stranger events = %v", events)
	}
	// A DM has no group record.
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{"kind": "dm", "member_account_ids": []string{bobID}})
	var dm struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(response, &dm)
	if status, _ = profilePut(t, handler, "/api/v1/conversations/"+dm.ID+"/profile", ownerToken, blob, testProfileKeyA, "*"); status != http.StatusNotFound {
		t.Fatalf("DM profile put = %d", status)
	}
	// Legacy title: only owner or admin may clear it.
	if status, _ = doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+group.ID+"/title", bobToken, nil); status != http.StatusForbidden {
		t.Fatalf("member clear title = %d", status)
	}
	if status, _ = doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+group.ID+"/title", strangerToken, nil); status != http.StatusNotFound {
		t.Fatalf("stranger clear title = %d", status)
	}
	if status, _ = doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+group.ID+"/title", ownerToken, nil); status != http.StatusNoContent {
		t.Fatalf("owner clear title = %d", status)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/conversations", ownerToken, nil)
	if status != http.StatusOK || bytes.Contains(response, []byte("Old plaintext")) {
		t.Fatalf("title still listed: %d %s", status, response)
	}
}
