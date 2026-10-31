package app

import (
	"context"
	"fmt"
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

func TestRateLimiterAdmitsNewClientsThroughOverflowWhenFull(t *testing.T) {
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

// A full table of live buckets must not recycle an exhausted credential
// budget: a full table evicts only buckets with no credential use (VAL-207).
func TestRateLimiterFullTableKeepsExhaustedCredentialBudget(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{general: 100, auth: 2, enrollment: 2, account: 100, signedIn: 100})
	if err != nil {
		t.Fatalf("new limiter: %v", err)
	}
	limiter.maxEntries = 4
	handler := limiter.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	send := func(ip, method, path string) int {
		request := httptest.NewRequest(method, path, nil)
		request.RemoteAddr = ip + ":4000"
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder.Code
	}
	const attacker = "203.0.113.9"
	for i := 0; i < 2; i++ {
		if code := send(attacker, http.MethodPost, "/api/v1/auth/login"); code == http.StatusTooManyRequests {
			t.Fatalf("login %d refused too early", i+1)
		}
	}
	if code := send(attacker, http.MethodPost, "/api/v1/auth/login"); code != http.StatusTooManyRequests {
		t.Fatalf("third login status=%d, want 429", code)
	}
	for i := 0; i < 20; i++ {
		send(fmt.Sprintf("198.51.100.%d", i+1), http.MethodGet, "/api/v1/health")
		limiter.mu.Lock()
		entries := len(limiter.buckets)
		limiter.mu.Unlock()
		if entries > limiter.maxEntries {
			t.Fatalf("address table holds %d buckets, cap is %d", entries, limiter.maxEntries)
		}
	}
	before := limiter.rejections[scopeAuth].Load()
	if code := send(attacker, http.MethodPost, "/api/v1/auth/login"); code != http.StatusTooManyRequests {
		t.Fatalf("credential budget was reset under table pressure: status=%d", code)
	}
	if got := limiter.rejections[scopeAuth].Load(); got != before+1 {
		t.Fatalf("auth rejections %d -> %d", before, got)
	}
	// Keys that found the table full are counted, and the table never grew.
	if _, pressure := limiter.stats(); pressure == 0 {
		t.Fatal("table-pressure events were not counted")
	}
}

// Account keys use the same rule in their own table.
func TestRateLimiterFullAccountTableKeepsLiveBuckets(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{general: 100, auth: 2, enrollment: 2, account: 1, signedIn: 100})
	if err != nil {
		t.Fatalf("new limiter: %v", err)
	}
	limiter.maxEntries = 3
	charge := func(account string) bool {
		ok, _ := (&accountCharge{limiter: limiter, host: "192.0.2.7"}).Authenticated(account)
		return ok
	}
	if !charge("acct_first") {
		t.Fatal("first account request refused")
	}
	if charge("acct_first") {
		t.Fatal("second request within the limit of 1 admitted")
	}
	for i := 0; i < 10; i++ {
		charge(fmt.Sprintf("acct_other_%d", i))
		limiter.mu.Lock()
		entries := len(limiter.accountBuckets)
		limiter.mu.Unlock()
		if entries > limiter.maxEntries {
			t.Fatalf("account table holds %d buckets, cap is %d", entries, limiter.maxEntries)
		}
	}
	if charge("acct_first") {
		t.Fatal("exhausted account budget was reset under table pressure")
	}
}

// One routed IPv6 /48 holds 65,536 /64 keys. An attacker that fills the
// address table with credential-using buckets and then burns its network's
// overflow bucket must not be able to refuse everyone else's first login
// (the shared overflow bucket let it).
func TestRateLimiterOverflowIsPerNetwork(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{general: 100, auth: 3, enrollment: 3, account: 100, signedIn: 100})
	if err != nil {
		t.Fatalf("new limiter: %v", err)
	}
	limiter.maxEntries = 8
	handler := limiter.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	login := func(ip string) int {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", nil)
		request.RemoteAddr = "[" + ip + "]:4000"
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder.Code
	}
	// The attacker owns 2001:db8:a::/48: eight /64s fill the table with
	// buckets that have used a credential budget, then more /64s of the same
	// /48 land in the overflow and exhaust it.
	for i := 0; i < 8; i++ {
		if code := login(fmt.Sprintf("2001:db8:a:%x::1", i)); code != http.StatusNoContent {
			t.Fatalf("attacker login %d status=%d", i, code)
		}
	}
	limited := 0
	for i := 0; i < 12; i++ {
		if login(fmt.Sprintf("2001:db8:a:%x::1", 0x100+i)) == http.StatusTooManyRequests {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("the attacker's own overflow bucket never ran out; the test is not exercising the overflow")
	}
	attackerShard := limiter.overflowShard(rateLimitHost("2001:db8:a:1::1"))
	for _, victim := range []string{"2001:db8:b::1", "2001:db8:c::1", "2001:db8:d::1"} {
		if limiter.overflowShard(rateLimitHost(victim)) == attackerShard {
			continue // a 1-in-256 salt collision; try the next network
		}
		if code := login(victim); code != http.StatusNoContent {
			t.Fatalf("an unrelated client's first login from %s was refused: %d", victim, code)
		}
		return
	}
	t.Fatal("no victim network avoided the attacker's shard")
}

// A full table prefers to evict the least used bucket with no credential or
// enrollment use, and never one that has used either.
func TestRateLimiterEvictsLeastUsedBucketWithoutCredentialUse(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{general: 100, auth: 3, enrollment: 3, account: 100, signedIn: 100})
	if err != nil {
		t.Fatal(err)
	}
	limiter.maxEntries = 4
	now := time.Now()
	live := now.Add(time.Minute)
	limiter.buckets["credential"] = &bucket{auth: 3, reset: live}
	limiter.buckets["enrollment"] = &bucket{enrollment: 1, reset: live}
	limiter.buckets["busy"] = &bucket{general: 50, reset: live}
	limiter.buckets["quiet"] = &bucket{general: 1, reset: live}
	limiter.mu.Lock()
	b := limiter.bucketLocked(limiter.buckets, &limiter.overflow, "198.51.100.1", "fresh", now)
	_, hasQuiet := limiter.buckets["quiet"]
	_, hasFresh := limiter.buckets["fresh"]
	size := len(limiter.buckets)
	limiter.mu.Unlock()
	if hasQuiet || !hasFresh || size != 4 || b != limiter.buckets["fresh"] {
		t.Fatalf("expected the quiet bucket to make room: quiet=%v fresh=%v size=%d", hasQuiet, hasFresh, size)
	}
	for _, key := range []string{"credential", "enrollment", "busy"} {
		if limiter.buckets[key] == nil {
			t.Fatalf("bucket %q was evicted", key)
		}
	}
	// With nothing evictable left, the next key uses its network's overflow.
	limiter.buckets["busy"].auth = 1
	limiter.buckets["fresh"].auth = 1
	limiter.mu.Lock()
	shared := limiter.bucketLocked(limiter.buckets, &limiter.overflow, "198.51.100.1", "another", now)
	size = len(limiter.buckets)
	limiter.mu.Unlock()
	if size != 4 || shared != &limiter.overflow[limiter.overflowShard("198.51.100.1")] {
		t.Fatalf("expected the overflow bucket of 198.51.100.0/24, size=%d", size)
	}
}

func TestOverflowShardGroupsByNetwork(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{})
	if err != nil {
		t.Fatal(err)
	}
	same := [][2]string{
		{"2001:db8:a:1::1", "2001:db8:a:ffff::9"}, // one /48
		{"198.51.100.1", "198.51.100.254"},        // one /24
		{"::ffff:198.51.100.1", "198.51.100.77"},  // mapped form
	}
	for _, pair := range same {
		if a, b := limiter.overflowShard(rateLimitHost(pair[0])), limiter.overflowShard(rateLimitHost(pair[1])); a != b {
			t.Errorf("%s and %s are in different shards: %d, %d", pair[0], pair[1], a, b)
		}
	}
	seen := map[int]bool{}
	for i := 0; i < 64; i++ {
		seen[limiter.overflowShard(rateLimitHost(fmt.Sprintf("2001:db8:%x::1", 0x1000+i)))] = true
	}
	if len(seen) < 32 {
		t.Errorf("64 networks landed in only %d of %d shards", len(seen), overflowShards)
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
