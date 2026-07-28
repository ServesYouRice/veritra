package httpapi_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRealtimeAuthorizesBeforeUpgrade(t *testing.T) {
	handler, _, _ := newTestHandlerWithOwnerDevice(t)
	request := httptest.NewRequest(http.MethodGet, "/api/v1/sync/ws", nil)
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized upgrade status=%d", recorder.Code)
	}
}
