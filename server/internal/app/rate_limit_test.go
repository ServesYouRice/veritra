package app

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/httpapi"
)

func TestEnrollmentLimiterUsesSpoofResistantProxyIdentity(t *testing.T) {
	_, proxyNetwork, err := net.ParseCIDR("172.28.250.0/24")
	if err != nil {
		t.Fatalf("parse proxy network: %v", err)
	}
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver([]*net.IPNet{proxyNetwork}), rateLimits{general: 100, auth: 100, enrollment: 2, account: 100, signedIn: 100})
	if err != nil {
		t.Fatalf("new limiter: %v", err)
	}
	handler := limiter.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	request := func(remoteAddr, forwardedFor string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/register/enrollment", nil)
		req.RemoteAddr = remoteAddr
		req.Header.Set("X-Forwarded-For", forwardedFor)
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, req)
		return recorder
	}
	if status := request("172.28.250.2:8080", "203.0.113.30").Code; status != http.StatusNoContent {
		t.Fatalf("first trusted client status=%d", status)
	}
	if status := request("172.28.250.2:8080", "203.0.113.30").Code; status != http.StatusNoContent {
		t.Fatalf("second trusted client status=%d", status)
	}
	limited := request("172.28.250.2:8080", "203.0.113.30")
	if limited.Code != http.StatusTooManyRequests {
		t.Fatalf("trusted client limit status=%d", limited.Code)
	}
	if retry, err := strconv.Atoi(limited.Header().Get("Retry-After")); err != nil || retry < 1 || retry > 60 {
		t.Fatalf("Retry-After=%q err=%v", limited.Header().Get("Retry-After"), err)
	}
	if status := request("172.28.250.2:8080", "203.0.113.31").Code; status != http.StatusNoContent {
		t.Fatalf("distinct trusted client collapsed into proxy bucket: %d", status)
	}

	if status := request("198.51.100.40:443", "203.0.113.41").Code; status != http.StatusNoContent {
		t.Fatalf("first untrusted client status=%d", status)
	}
	if status := request("198.51.100.40:443", "203.0.113.42").Code; status != http.StatusNoContent {
		t.Fatalf("second untrusted client status=%d", status)
	}
	if status := request("198.51.100.40:443", "203.0.113.43").Code; status != http.StatusTooManyRequests {
		t.Fatalf("untrusted forwarding spoof bypassed limit: %d", status)
	}
}

func TestRecoveryRouteUsesCredentialRateLimit(t *testing.T) {
	if httpapi.ClassifyRoute("/api/v1/recovery") != httpapi.CredentialRoute {
		t.Fatal("recovery route is not in the strict credential rate class")
	}
	if httpapi.ClassifyRoute("/api/v1/recovery/secret") == httpapi.CredentialRoute {
		t.Fatal("legacy token path unexpectedly accepted as credential route")
	}
	if httpapi.ClassifyRoute("/api/v1/auth/reauth") != httpapi.CredentialRoute {
		t.Fatal("reauth route is not in the strict credential rate class")
	}
}

// Through the real router: every spelling that reaches the claim-status
// handler is a credential request (10 a minute per address), and the
// device-link enrollment reservation is an enrollment request (5).
func TestDeviceLinkRoutesUseTheirFixedBudgets(t *testing.T) {
	application, err := New(context.Background(), deploymentConfig(t), slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	send := func(address, method, path string) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(method, path, strings.NewReader(`{"code":"not-a-link-code"}`))
		request.RemoteAddr = address + ":40000"
		request.Header.Set("Content-Type", "application/json")
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder
	}
	rejected := func(scope int) int64 { return application.limiter.rejections[scope].Load() }

	const prober = "203.0.113.70"
	for i, path := range []string{
		"/api/v1/device-links/link_x/claim-status/",
		"/api/v1/device-links/link_x/claim-status",
		"/api/v1/device-links/link_x%2Fclaim-status%2F",
	} {
		recorder := send(prober, http.MethodGet, path)
		if recorder.Code != http.StatusBadRequest || !strings.Contains(recorder.Body.String(), "claim_token_required") {
			t.Fatalf("%s did not reach the claim-status handler: %d %s", path, recorder.Code, recorder.Body.String())
		}
		if i == 0 {
			for j := 0; j < 7; j++ {
				send(prober, http.MethodGet, path)
			}
		}
	}
	before := rejected(scopeAuth)
	if code := send(prober, http.MethodGet, "/api/v1/device-links/link_y/claim-status/").Code; code != http.StatusTooManyRequests {
		t.Fatalf("eleventh claim-status probe status=%d, want 429", code)
	}
	if got := rejected(scopeAuth); got != before+1 {
		t.Fatalf("auth rejections %d -> %d", before, got)
	}

	const enroller = "203.0.113.71"
	for i := 0; i < enrollmentRequestsPerMinute; i++ {
		if code := send(enroller, http.MethodPost, "/api/v1/device-links/claim-enrollment").Code; code == http.StatusTooManyRequests || code == http.StatusNotFound {
			t.Fatalf("claim-enrollment %d status=%d", i+1, code)
		}
	}
	before = rejected(scopeEnrollment)
	if code := send(enroller, http.MethodPost, "/api/v1/device-links/claim-enrollment").Code; code != http.StatusTooManyRequests {
		t.Fatalf("sixth claim-enrollment status=%d, want 429", code)
	}
	if got := rejected(scopeEnrollment); got != before+1 {
		t.Fatalf("enrollment rejections %d -> %d", before, got)
	}
}

func TestRateLimiterEvictsInsteadOfRefusingNewClients(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{general: 100, auth: 100, enrollment: 100, account: 100, signedIn: 100})
	if err != nil {
		t.Fatalf("new limiter: %v", err)
	}
	now := time.Now()
	limiter.mu.Lock()
	for i := 0; i < maxRateLimitEntries; i++ {
		limiter.buckets["filled-"+strconv.Itoa(i)] = &bucket{reset: now.Add(time.Minute)}
	}
	limiter.mu.Unlock()
	handler := limiter.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	request.RemoteAddr = "198.51.100.250:443"
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("new client was refused under table pressure: %d", recorder.Code)
	}
	if limiter.evictions.Load() != 1 {
		t.Fatalf("evictions=%d want 1", limiter.evictions.Load())
	}
}

func TestRemoteHashGroupsIPv6BySlash64(t *testing.T) {
	salt := []byte("test-salt")
	if got, want := remoteHash(salt, "2001:db8:1:2::1"), remoteHash(salt, "2001:db8:1:2::ffff"); got != want {
		t.Fatalf("same IPv6 /64 produced different keys: %q != %q", got, want)
	}
	if got, want := remoteHash(salt, "2001:db8:1:2::1"), remoteHash(salt, "2001:db8:1:3::1"); got == want {
		t.Fatalf("different IPv6 /64 produced the same key: %q", got)
	}
}
