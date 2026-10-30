package httpapi

import (
	"net/http"
	"net/http/httptest"
	"private-messenger/server/internal/domain"
	"testing"
)

func TestHistoryTransferUnsupportedBlobBackendFailsClosed(t *testing.T) {
	api := API{Blobs: &downloadTestStore{}}
	w := httptest.NewRecorder()
	api.uploadHistoryTransfer(w, httptest.NewRequest(http.MethodPost, "/history", nil), domain.Principal{})
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("unsupported backend %d", w.Code)
	}
}
