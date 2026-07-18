package httpapi

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"private-messenger/server/internal/storage"
)

func TestHandleStorageErrorReportsQuotaExhaustion(t *testing.T) {
	recorder := httptest.NewRecorder()

	handleStorageError(recorder, storage.ErrStorageQuota)

	if recorder.Code != http.StatusInsufficientStorage {
		t.Fatalf("status=%d want %d", recorder.Code, http.StatusInsufficientStorage)
	}
	if !bytes.Contains(recorder.Body.Bytes(), []byte(`"error":"storage_quota_exceeded"`)) {
		t.Fatalf("body=%s", recorder.Body.String())
	}
}
