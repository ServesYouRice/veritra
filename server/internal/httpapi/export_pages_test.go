package httpapi_test

import (
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
)

// The export pages through messages. Its associated-data categories come with
// the first page; later pages keep the key, with nothing in it.
func TestAccountExportCategoriesComeWithTheFirstPageOnly(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwnerDevice(t)
	conversationID := createConversation(t, handler, token)
	for _, key := range []string{"export-a", "export-b", "export-c"} {
		createMessage(t, handler, token, conversationID, key, []byte("ciphertext-"+key))
	}
	type page struct {
		Messages   []json.RawMessage            `json:"messages"`
		Categories map[string][]json.RawMessage `json:"categories"`
		NextBefore string                       `json:"next_before"`
	}
	get := func(query string) (page, []byte) {
		t.Helper()
		status, body := doJSON(t, handler, http.MethodGet, "/api/v1/account/export?"+query, token, nil)
		if status != http.StatusOK {
			t.Fatalf("export %q: status=%d body=%s", query, status, body)
		}
		var decoded page
		if err := json.Unmarshal(body, &decoded); err != nil {
			t.Fatalf("decode export: %v", err)
		}
		return decoded, body
	}
	first, _ := get("limit=2")
	if len(first.Messages) != 2 || first.NextBefore == "" || len(first.Categories["memberships"]) == 0 {
		t.Fatalf("first page: %d messages, next_before %q, memberships %d", len(first.Messages), first.NextBefore, len(first.Categories["memberships"]))
	}
	second, body := get("limit=2&before=" + url.QueryEscape(first.NextBefore))
	if len(second.Messages) != 1 {
		t.Fatalf("second page has %d messages, want the last one", len(second.Messages))
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatal(err)
	}
	if string(raw["categories"]) != "{}" {
		t.Fatalf("second page categories = %s, want an empty object", raw["categories"])
	}
}
