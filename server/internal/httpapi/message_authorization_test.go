package httpapi_test

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"testing"
)

// Only a message's author may edit or delete it. A conversation member who
// did not write it and an account outside the conversation are both refused,
// and the stored envelope stays as the author left it (VAL-216).
func TestMessageEditAndDeleteRefuseNonAuthors(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "reader")
	outsiderToken := registerMember(t, handler, ownerToken, "outsider")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	original := []byte("author-ciphertext")
	messageID := createMessage(t, handler, ownerToken, conversationID, "author-message", original)

	type envelope struct {
		Ciphertext string  `json:"ciphertext"`
		EditedAt   *string `json:"edited_at"`
		DeletedAt  *string `json:"deleted_at"`
	}
	fetch := func(token string) envelope {
		t.Helper()
		status, response := doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+messageID, token, nil)
		if status != http.StatusOK {
			t.Fatalf("fetch message status=%d body=%s", status, response)
		}
		var decoded envelope
		if err := json.Unmarshal(response, &decoded); err != nil {
			t.Fatalf("decode message: %v", err)
		}
		return decoded
	}
	assertUnchanged := func(when string) {
		t.Helper()
		got := fetch(ownerToken)
		if got.Ciphertext != base64.StdEncoding.EncodeToString(original) || got.EditedAt != nil || got.DeletedAt != nil {
			t.Fatalf("%s: message changed: %+v", when, got)
		}
		// A refused member also sees the message unchanged.
		if member := fetch(memberToken); member != got {
			t.Fatalf("%s: member sees %+v, author sees %+v", when, member, got)
		}
	}
	assertUnchanged("before any attempt")

	body := map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("hijacked-ciphertext")),
		"crypto_protocol": "mls10-openmls-v1",
	}
	for _, actor := range []struct{ name, token string }{{"member who is not the author", memberToken}, {"account outside the conversation", outsiderToken}} {
		for _, action := range []string{"edit", "delete"} {
			status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/"+action, actor.token, body)
			if status != http.StatusForbidden {
				t.Fatalf("%s: %s status=%d body=%s, want 403", actor.name, action, status, response)
			}
			assertUnchanged(actor.name + " " + action)
		}
	}

	// The author still can.
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/edit", ownerToken, body)
	if status != http.StatusOK {
		t.Fatalf("author edit status=%d body=%s", status, response)
	}
	if got := fetch(ownerToken); got.EditedAt == nil || got.Ciphertext != body["ciphertext"] {
		t.Fatalf("author edit not stored: %+v", got)
	}
}
