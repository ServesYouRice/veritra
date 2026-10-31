package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
)

// An update-only commit bundle (periodic self-update) is accepted on the
// current epoch, and a second one from the same device inside the interval
// answers 429 with a Retry-After the app can honour.
func TestMLSUpdateOnlyCommitRoute(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, ownerToken)
	path := "/api/v1/conversations/" + conversationID + "/mls/commits"
	status, response := doJSON(t, handler, http.MethodPost, path, ownerToken,
		map[string]interface{}{"epoch": 0, "idempotency_key": "genesis"})
	if status != http.StatusCreated {
		t.Fatalf("genesis status=%d body=%s", status, response)
	}
	update := func(epoch int, key string) *httptest.ResponseRecorder {
		raw, _ := json.Marshal(map[string]interface{}{
			"epoch": epoch, "idempotency_key": key,
			"commit": base64.StdEncoding.EncodeToString([]byte("update-" + key)),
		})
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+ownerToken)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	if rec := update(0, "update-1"); rec.Code != http.StatusCreated ||
		!bytes.Contains(rec.Body.Bytes(), []byte(`"epoch":1`)) || !bytes.Contains(rec.Body.Bytes(), []byte(`"kind":"commit"`)) {
		t.Fatalf("update status=%d body=%s", rec.Code, rec.Body.Bytes())
	}
	if rec := update(0, "update-1"); rec.Code != http.StatusOK {
		t.Fatalf("retry status=%d body=%s", rec.Code, rec.Body.Bytes())
	}
	if rec := update(0, "stale"); rec.Code != http.StatusConflict || !bytes.Contains(rec.Body.Bytes(), []byte("mls_epoch_conflict")) {
		t.Fatalf("stale status=%d body=%s", rec.Code, rec.Body.Bytes())
	}
	rec := update(1, "update-2")
	retryAfter, err := strconv.Atoi(rec.Header().Get("Retry-After"))
	if rec.Code != http.StatusTooManyRequests || !bytes.Contains(rec.Body.Bytes(), []byte("mls_self_update_limit")) ||
		err != nil || retryAfter < 3000 || retryAfter > 3600 {
		t.Fatalf("second update status=%d retry-after=%q body=%s", rec.Code, rec.Header().Get("Retry-After"), rec.Body.Bytes())
	}
}
