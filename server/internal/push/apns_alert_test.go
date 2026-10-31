package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"private-messenger/server/internal/domain"
)

// sendAPNs builds one APNs request for mode and returns its headers and the
// decoded JSON body.
func sendAPNs(t *testing.T, mode string) (http.Header, map[string]any) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	provider, err := NewAPNsProvider(APNsConfig{TeamID: "T", KeyID: "K", BundleID: "org.veritra", PrivateKey: pkcs8PEM(t, key)})
	if err != nil {
		t.Fatal(err)
	}
	var header http.Header
	var body map[string]any
	provider.client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		header = r.Header.Clone()
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		return respond(200, `{}`), nil
	})}
	if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "apns", Endpoint: strings.Repeat("a", 64), NotificationMode: mode}); err != nil {
		t.Fatal(err)
	}
	return header, body
}

// D53: the legacy wake is a visible alert whose only text is a fixed loc-key
// resolved in the app bundle, so it shows without background execution and
// the server sends no language-specific text and nothing about the message.
func TestAPNsLegacyWakeIsAGenericLocalizedAlert(t *testing.T) {
	for _, mode := range []string{"", domain.PushNotificationLegacy} {
		header, body := sendAPNs(t, mode)
		for name, want := range map[string]string{"apns-push-type": "alert", "apns-priority": "10", "apns-collapse-id": "veritra-new-message"} {
			if got := header.Get(name); got != want {
				t.Fatalf("mode %q: %s=%q, want %q", mode, name, got, want)
			}
		}
		want := map[string]any{
			"aps": map[string]any{
				"alert":             map[string]any{"loc-key": "veritra.notification.new_message"},
				"sound":             "default",
				"content-available": float64(1),
			},
			"version": "v1",
			"event":   "new_encrypted_event_available",
		}
		// Exact equality: any extra field (text, sender, conversation,
		// count, badge) fails here.
		if !reflect.DeepEqual(body, want) {
			t.Fatalf("mode %q: APNs body=%v", mode, body)
		}
	}
}

// D52: the local-decrypt wake stays silent; the device decides after
// decryption whether anything is shown.
func TestAPNsLocalDecryptWakeStaysSilent(t *testing.T) {
	header, body := sendAPNs(t, domain.PushNotificationLocalDecrypt)
	if header.Get("apns-push-type") != "background" || header.Get("apns-priority") != "5" || header.Get("apns-collapse-id") != "veritra-sync" {
		t.Fatalf("silent wake headers changed: %v", header)
	}
	want := map[string]any{
		"aps":          map[string]any{"content-available": float64(1)},
		"version":      "v2",
		"event":        "new_encrypted_event_available",
		"presentation": "none",
	}
	if !reflect.DeepEqual(body, want) {
		t.Fatalf("APNs body=%v", body)
	}
}
