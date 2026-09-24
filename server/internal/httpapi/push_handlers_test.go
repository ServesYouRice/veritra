package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/push"
	"private-messenger/server/internal/storage"
	"private-messenger/server/migrations"
)

// Card I41: provider-aware registration, a privacy-safe test wake and
// diagnostics without endpoints or tokens.

type recordingPush struct {
	mu   sync.Mutex
	sent []push.Notification
	err  error
}

func (p *recordingPush) SendEncryptedEventAvailable(_ context.Context, notification push.Notification) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sent = append(p.sent, notification)
	return p.err
}

func newPushTestAPI(t *testing.T, providers ...string) (*API, domain.Principal, *recordingPush) {
	t.Helper()
	dir := t.TempDir()
	store, err := storage.Open(context.Background(), config.Config{
		DataDir: dir, DatabasePath: filepath.Join(dir, "db.sqlite"), StoragePath: filepath.Join(dir, "blobs"),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	if err := store.Migrate(context.Background(), migrations.FS); err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveOwnerEnrollment(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	owner, err := store.CreateOwner(context.Background(), storage.CreateOwnerInput{
		EnrollmentReservationID: reservation.ID, InstanceName: "push", Username: "owner",
		PasswordHash: "x", DeviceName: "phone", KeyPackage: []byte("kp"), SigningKey: bytes.Repeat([]byte{1}, 32),
	})
	if err != nil {
		t.Fatal(err)
	}
	provider := &recordingPush{}
	api := &API{Store: store, Push: provider, PushProviders: providers, VAPIDPublicKey: "vapid-public"}
	return api, domain.Principal{AccountID: owner.Account.ID, DeviceID: owner.Device.ID}, provider
}

func call(t *testing.T, handler func(http.ResponseWriter, *http.Request, domain.Principal), principal domain.Principal, method, body string) (int, map[string]any) {
	t.Helper()
	request := httptest.NewRequest(method, "/", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	handler(recorder, request, principal)
	var decoded map[string]any
	_ = json.Unmarshal(recorder.Body.Bytes(), &decoded)
	return recorder.Code, decoded
}

const fcmToken = "fcm-token-0123456789-0123456789-0123456789"

func TestPushConfigIsProviderAware(t *testing.T) {
	api, principal, _ := newPushTestAPI(t, "fcm")
	_, body := call(t, api.pushConfig, principal, http.MethodGet, "")
	if _, ok := body["vapid_public_key"]; ok {
		t.Fatalf("FCM-only config carries a VAPID key: %v", body)
	}
	if body["enabled"] != true || body["payload_policy"] != "generic_encrypted_event_only" {
		t.Fatalf("config=%v", body)
	}
	api.PushProviders = []string{"webpush", "fcm"}
	if _, body = call(t, api.pushConfig, principal, http.MethodGet, ""); body["vapid_public_key"] != "vapid-public" {
		t.Fatalf("Web Push config lacks its key: %v", body)
	}
}

func TestPushRegistrationRejectsUnofferedProvidersAndRotates(t *testing.T) {
	api, principal, _ := newPushTestAPI(t, "fcm")
	status, body := call(t, api.createPushSubscription, principal, http.MethodPost,
		`{"provider":"apns","endpoint":"`+strings.Repeat("a", 64)+`"}`)
	if status != http.StatusBadRequest || body["error"] != "push_provider_unavailable" {
		t.Fatalf("unoffered provider status=%d body=%v", status, body)
	}
	status, first := call(t, api.createPushSubscription, principal, http.MethodPost,
		`{"provider":"fcm","endpoint":"`+fcmToken+`"}`)
	if status != http.StatusCreated {
		t.Fatalf("fcm status=%d body=%v", status, first)
	}
	// A rotated token keeps one registration.
	_, second := call(t, api.createPushSubscription, principal, http.MethodPost,
		`{"provider":"fcm","endpoint":"`+fcmToken+`-rotated"}`)
	if first["subscription_id"] != second["subscription_id"] {
		t.Fatalf("rotation created a second registration: %v %v", first, second)
	}
	// Switching provider retires the old registration.
	api.PushProviders = []string{"fcm", "apns"}
	call(t, api.createPushSubscription, principal, http.MethodPost,
		`{"provider":"apns","endpoint":"`+strings.Repeat("b", 64)+`"}`)
	_, list := call(t, api.listDevicePushSubscriptions, principal, http.MethodGet, "")
	subscriptions := list["subscriptions"].([]any)
	if len(subscriptions) != 1 || subscriptions[0].(map[string]any)["provider"] != "apns" {
		t.Fatalf("subscriptions=%v", subscriptions)
	}
	raw, _ := json.Marshal(list)
	for _, secret := range []string{fcmToken, strings.Repeat("b", 64), "endpoint", "auth_secret"} {
		if bytes.Contains(raw, []byte(secret)) {
			t.Fatalf("diagnostics leak %q: %s", secret, raw)
		}
	}
}

func TestTestPushSendsTheGenericWakeAndIsRateLimited(t *testing.T) {
	api, principal, provider := newPushTestAPI(t, "fcm")
	if status, body := call(t, api.sendTestPush, principal, http.MethodPost, ""); status != http.StatusNotFound || body["error"] != "no_push_subscription" {
		t.Fatalf("no subscription status=%d body=%v", status, body)
	}
	api.pushTestLast = nil
	call(t, api.createPushSubscription, principal, http.MethodPost, `{"provider":"fcm","endpoint":"`+fcmToken+`"}`)
	status, body := call(t, api.sendTestPush, principal, http.MethodPost, "")
	if status != http.StatusOK {
		t.Fatalf("test push status=%d body=%v", status, body)
	}
	results := body["results"].([]any)
	if len(results) != 1 || results[0].(map[string]any)["result"] != "delivered" {
		t.Fatalf("results=%v", results)
	}
	if len(provider.sent) != 1 || provider.sent[0].Endpoint != fcmToken {
		t.Fatalf("sent=%v", provider.sent)
	}
	raw, _ := json.Marshal(body)
	if bytes.Contains(raw, []byte(fcmToken)) {
		t.Fatalf("test push response leaks the token: %s", raw)
	}
	if status, _ := call(t, api.sendTestPush, principal, http.MethodPost, ""); status != http.StatusTooManyRequests {
		t.Fatalf("second test within a minute status=%d", status)
	}
	// A gone registration is retired and reported as such.
	api.pushTestLast[principal.DeviceID] = time.Now().Add(-2 * time.Minute)
	provider.err = push.ErrSubscriptionGone
	if _, body = call(t, api.sendTestPush, principal, http.MethodPost, ""); body["results"].([]any)[0].(map[string]any)["result"] != "gone" {
		t.Fatalf("gone results=%v", body)
	}
	if _, list := call(t, api.listDevicePushSubscriptions, principal, http.MethodGet, ""); len(list["subscriptions"].([]any)) != 0 {
		t.Fatalf("gone registration still listed: %v", list)
	}
}
