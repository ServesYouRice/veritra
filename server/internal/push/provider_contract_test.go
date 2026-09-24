package push

// QA06 (card I41): provider request contracts with generated keys and an
// injected transport. No request leaves the process.

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func respond(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}
}

func pkcs8PEM(t *testing.T, key any) string {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func jwtHeader(t *testing.T, token string) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("not a JWT: %q", token)
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatal(err)
	}
	var header map[string]any
	if err := json.Unmarshal(raw, &header); err != nil {
		t.Fatal(err)
	}
	return header
}

const testFCMToken = "fcm-device-token-0123456789-abcdefghijklmnop"

func newTestFCM(t *testing.T, handler roundTrip) *FCMProvider {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	provider, err := NewFCMProvider(FCMConfig{ProjectID: "demo-project", ClientEmail: "svc@demo.iam", PrivateKey: pkcs8PEM(t, key)})
	if err != nil {
		t.Fatal(err)
	}
	provider.client = &http.Client{Transport: handler}
	return provider
}

func TestFCMRequestContract(t *testing.T) {
	var oauthCalls, sends atomic.Int32
	var sentBody map[string]any
	var mu sync.Mutex
	provider := newTestFCM(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Host + r.URL.Path {
		case "oauth2.googleapis.com/token":
			oauthCalls.Add(1)
			if err := r.ParseForm(); err != nil || r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
				t.Errorf("oauth form=%v", r.Form)
			}
			if header := jwtHeader(t, r.Form.Get("assertion")); header["alg"] != "RS256" {
				t.Errorf("assertion header=%v", header)
			}
			return respond(200, `{"access_token":"access-1","expires_in":3600}`), nil
		case "fcm.googleapis.com/v1/projects/demo-project/messages:send":
			sends.Add(1)
			if r.Header.Get("Authorization") != "Bearer access-1" {
				t.Errorf("authorization=%q", r.Header.Get("Authorization"))
			}
			mu.Lock()
			_ = json.NewDecoder(r.Body).Decode(&sentBody)
			mu.Unlock()
			return respond(200, `{}`), nil
		}
		t.Errorf("unexpected request %s", r.URL)
		return respond(500, ""), nil
	})
	for i := 0; i < 2; i++ {
		if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "fcm", Endpoint: testFCMToken}); err != nil {
			t.Fatal(err)
		}
	}
	if oauthCalls.Load() != 1 || sends.Load() != 2 {
		t.Fatalf("oauth=%d sends=%d; the access token must be reused", oauthCalls.Load(), sends.Load())
	}
	message := sentBody["message"].(map[string]any)
	data := message["data"].(map[string]any)
	if message["token"] != testFCMToken || data["event"] != "new_encrypted_event_available" || len(data) != 2 {
		t.Fatalf("message=%v", message)
	}
	if _, ok := message["notification"]; ok {
		t.Fatal("FCM message carries a visible notification")
	}
}

func TestFCMClassifiesProviderAnswers(t *testing.T) {
	for name, test := range map[string]struct {
		status int
		body   string
		gone   bool
	}{
		"not found":    {404, `{}`, true},
		"unregistered": {400, `{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}`, true},
		"server error": {503, `{}`, false},
		"huge body":    {500, strings.Repeat("x", 1<<20), false},
	} {
		t.Run(name, func(t *testing.T) {
			provider := newTestFCM(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Host == "oauth2.googleapis.com" {
					return respond(200, `{"access_token":"a","expires_in":3600}`), nil
				}
				return respond(test.status, test.body), nil
			})
			err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "fcm", Endpoint: testFCMToken})
			if test.gone != errors.Is(err, ErrSubscriptionGone) || err == nil {
				t.Fatalf("err=%v gone=%v", err, test.gone)
			}
		})
	}
	provider := newTestFCM(t, func(r *http.Request) (*http.Response, error) { return respond(200, `{"expires_in":1}`), nil })
	if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "fcm", Endpoint: testFCMToken}); err == nil {
		t.Fatal("a malformed OAuth answer was accepted")
	}
	if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "fcm", Endpoint: "short"}); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("invalid token err=%v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cancelled := newTestFCM(t, func(r *http.Request) (*http.Response, error) { return nil, r.Context().Err() })
	if err := cancelled.SendEncryptedEventAvailable(ctx, Notification{Provider: "fcm", Endpoint: testFCMToken}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled err=%v", err)
	}
}

func TestAPNsRequestContractAndPKCS8Keys(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	token := strings.Repeat("ab", 32)
	var request *http.Request
	var body map[string]any
	provider, err := NewAPNsProvider(APNsConfig{TeamID: "TEAM", KeyID: "KEY1", BundleID: "org.veritra.app", PrivateKey: pkcs8PEM(t, key), Sandbox: true})
	if err != nil {
		t.Fatalf("a PKCS #8 .p8 key was refused: %v", err)
	}
	status := 200
	answer := `{}`
	provider.client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		request = r
		_ = json.NewDecoder(r.Body).Decode(&body)
		return respond(status, answer), nil
	})}
	if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "apns", Endpoint: token}); err != nil {
		t.Fatal(err)
	}
	if request.URL.String() != "https://api.sandbox.push.apple.com/3/device/"+token {
		t.Fatalf("url=%s", request.URL)
	}
	for header, want := range map[string]string{"apns-topic": "org.veritra.app", "apns-push-type": "background", "apns-priority": "5"} {
		if request.Header.Get(header) != want {
			t.Fatalf("%s=%q", header, request.Header.Get(header))
		}
	}
	jwt := strings.TrimPrefix(request.Header.Get("Authorization"), "bearer ")
	if header := jwtHeader(t, jwt); header["alg"] != "ES256" || header["kid"] != "KEY1" {
		t.Fatalf("jwt header=%v", header)
	}
	aps := body["aps"].(map[string]any)
	if aps["content-available"] != float64(1) || len(aps) != 1 || body["event"] != "new_encrypted_event_available" {
		t.Fatalf("body=%v", body)
	}
	for _, answerCase := range []struct {
		status int
		body   string
	}{{410, `{}`}, {400, `{"reason":"BadDeviceToken"}`}} {
		status, answer = answerCase.status, answerCase.body
		if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "apns", Endpoint: token}); !errors.Is(err, ErrSubscriptionGone) {
			t.Fatalf("%d %s err=%v", status, answer, err)
		}
	}
	status, answer = 503, `{}`
	if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "apns", Endpoint: token}); err == nil || errors.Is(err, ErrSubscriptionGone) {
		t.Fatalf("retryable err=%v", err)
	}
	// A SEC 1 key still works.
	der, _ := x509.MarshalECPrivateKey(key)
	sec1 := string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}))
	if _, err := NewAPNsProvider(APNsConfig{TeamID: "T", KeyID: "K", BundleID: "b", PrivateKey: sec1}); err != nil {
		t.Fatal(err)
	}
}

func TestWebPushRefusesPrivateTargetsAndRedirects(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		http.Redirect(w, &http.Request{}, "https://example.com/", http.StatusFound)
	}))
	defer server.Close()
	curve := elliptic.P256()
	private, x, y, err := elliptic.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	provider, err := NewWebPushProvider(WebPushConfig{
		Subscriber: "mailto:ops@example.org",
		PublicKey:  base64.RawURLEncoding.EncodeToString(elliptic.Marshal(curve, x, y)),
		PrivateKey: base64.RawURLEncoding.EncodeToString(private),
	})
	if err != nil {
		t.Fatal(err)
	}
	_, px, py, _ := elliptic.GenerateKey(curve, rand.Reader)
	target := Notification{
		Provider:   "webpush",
		Endpoint:   server.URL + "/push",
		PublicKey:  base64.RawURLEncoding.EncodeToString(elliptic.Marshal(curve, px, py)),
		AuthSecret: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef")),
	}
	if err := provider.SendEncryptedEventAvailable(context.Background(), target); err == nil {
		t.Fatal("a loopback push endpoint was contacted")
	}
	if hits.Load() != 0 {
		t.Fatal("the request reached a private address")
	}
	target.Endpoint = "http://push.example.org/x"
	if err := ValidateWebPushTarget(target); err == nil {
		t.Fatal("a plain-HTTP endpoint was accepted")
	}
}
