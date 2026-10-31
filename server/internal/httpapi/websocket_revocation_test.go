package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/realtime"
)

// A handshake that authenticated and then lost its session to a logout (which
// deletes the session and disconnects the device's registered sockets) before
// it registered with the hub must not keep a subscription (VAL-223).
func TestWebSocketAdmissionRechecksSessionAfterRegister(t *testing.T) {
	api, principal, _ := newPushTestAPI(t, "fcm")
	api.Hub = realtime.NewHub()
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := api.Store.CreateSession(context.Background(), tokenHash, principal.AccountID, principal.DeviceID, time.Time{}); err != nil {
		t.Fatal(err)
	}
	// Logout between authentication and registration: delete the session,
	// then disconnect whatever is registered (nothing yet).
	api.beforeWebSocketRegister = func() {
		if err := api.Store.DeleteSession(context.Background(), tokenHash); err != nil {
			t.Errorf("delete session: %v", err)
		}
		api.Hub.DisconnectDevice(principal.AccountID, principal.DeviceID)
	}
	server := httptest.NewServer(http.HandlerFunc(api.syncWebSocket))
	t.Cleanup(server.Close)

	request, err := http.NewRequest(http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = response.Body.Close() })
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked session was admitted: status=%d", response.StatusCode)
	}
	if got := api.Hub.ConnectionCount(); got != 0 {
		t.Fatalf("hub still holds %d registration(s) for a revoked session", got)
	}
}
