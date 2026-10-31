package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"
)

type conversationListPage struct {
	Conversations []struct {
		ID            string     `json:"id"`
		CreatedAt     time.Time  `json:"created_at"`
		LastMessageAt *time.Time `json:"last_message_at"`
	} `json:"conversations"`
}

func listConversationPage(t *testing.T, handler http.Handler, token, query string) (int, conversationListPage, []byte) {
	t.Helper()
	status, body := doJSON(t, handler, http.MethodGet, "/api/v1/conversations?"+query, token, nil)
	var page conversationListPage
	if status == http.StatusOK {
		if err := json.Unmarshal(body, &page); err != nil {
			t.Fatalf("decode conversations: %v", err)
		}
	}
	return status, page, body
}

func TestConversationListCursorCarriesActivityAndRejectsGoneConversation(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwnerDevice(t)
	first := createConversation(t, handler, token)
	second := createConversation(t, handler, token)
	third := createConversation(t, handler, token)

	status, page, body := listConversationPage(t, handler, token, "limit=1")
	if status != http.StatusOK || len(page.Conversations) != 1 || page.Conversations[0].ID != third {
		t.Fatalf("first page status=%d body=%s", status, body)
	}
	cursor := page.Conversations[0]
	query := "limit=1&before=" + url.QueryEscape(cursor.ID) + "&before_activity=" + url.QueryEscape(cursor.CreatedAt.UTC().Format(time.RFC3339Nano))
	status, page, body = listConversationPage(t, handler, token, query)
	if status != http.StatusOK || len(page.Conversations) != 1 || page.Conversations[0].ID != second {
		t.Fatalf("second page status=%d body=%s, want %s", status, body, second)
	}
	// The id-only form older clients send keeps working.
	status, page, body = listConversationPage(t, handler, token, "limit=5&before="+url.QueryEscape(second))
	if status != http.StatusOK || len(page.Conversations) != 1 || page.Conversations[0].ID != first {
		t.Fatalf("id-only page status=%d body=%s, want %s", status, body, first)
	}
	for name, query := range map[string]string{
		"activity without a cursor id": "before_activity=" + url.QueryEscape(time.Now().UTC().Format(time.RFC3339Nano)),
		"unparsable activity":          "before=" + url.QueryEscape(second) + "&before_activity=yesterday",
		"unknown conversation":         "before=conv_00000000000000000000000000000000",
	} {
		status, _, body = listConversationPage(t, handler, token, query)
		if status != http.StatusBadRequest || !bytes.Contains(body, []byte("invalid_cursor")) {
			t.Fatalf("%s: status=%d body=%s, want 400 invalid_cursor", name, status, body)
		}
	}
}
