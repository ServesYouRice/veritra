package app

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

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
