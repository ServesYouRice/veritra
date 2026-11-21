package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"net/http"
	"testing"
)

// The single-message MLS route serves only groups that are already legacy
// (docs/crypto.md, "K0 R2 review"). A member posting a junk first message
// into a fresh conversation is refused with mls_commit_bundle_required, so
// it cannot make the conversation legacy and block the creator's first
// commit bundle.
func TestLegacyMLSRouteCannotBlockTheCreatorsFirstBundle(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "legacyjunk")
	conversationID := createConversation(t, handler, ownerToken)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken,
		map[string]interface{}{"account_id": memberID})
	if status != http.StatusCreated && status != http.StatusNoContent && status != http.StatusOK {
		t.Fatalf("add member status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/mls/messages", memberToken, map[string]interface{}{
		"kind": "commit", "idempotency_key": "junk", "payload": base64.StdEncoding.EncodeToString([]byte("junk")),
	})
	if status != http.StatusConflict || !bytes.Contains(response, []byte(`"mls_commit_bundle_required"`)) {
		t.Fatalf("junk first message status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/mls/commits", ownerToken,
		map[string]interface{}{"epoch": 0, "idempotency_key": "genesis"})
	if status != http.StatusCreated || !bytes.Contains(response, []byte(`"epoch":0`)) {
		t.Fatalf("creator's genesis after the junk status=%d body=%s", status, response)
	}
}
