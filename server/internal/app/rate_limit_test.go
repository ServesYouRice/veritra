package app

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"private-messenger/server/internal/httpapi"
)

func TestEnrollmentLimiterUsesSpoofResistantProxyIdentity(t *testing.T) {
	_, proxyNetwork, err := net.ParseCIDR("172.28.250.0/24")
	if err != nil {
		t.Fatalf("parse proxy network: %v", err)
	}
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver([]*net.IPNet{proxyNetwork}), 100, 100, 2)
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
	if !isAuthEndpoint("/api/v1/recovery") {
		t.Fatal("recovery route is not in the strict credential rate class")
	}
	if isAuthEndpoint("/api/v1/recovery/secret") {
		t.Fatal("legacy token path unexpectedly accepted as credential route")
	}
	if !isAuthEndpoint("/api/v1/auth/reauth") {
		t.Fatal("reauth route is not in the strict credential rate class")
	}
}

func TestRateLimiterEvictsInsteadOfRefusingNewClients(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), 100, 100, 100)
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
