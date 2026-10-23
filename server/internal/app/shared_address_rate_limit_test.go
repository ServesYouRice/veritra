package app

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/storage"
)

// memberSession registers another account through an invite and gives it a
// session with the bearer token token.
func memberSession(t *testing.T, application *App, ownerID, username, token string) {
	t.Helper()
	ctx := context.Background()
	invite, err := application.Store.CreateInvite(ctx, ownerID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := application.Store.ReserveRegistrationEnrollment(ctx, invite.Code)
	if err != nil {
		t.Fatal(err)
	}
	member, err := application.Store.RegisterWithInvite(ctx, storage.RegisterInput{
		EnrollmentReservationID: reservation.ID,
		InviteCode:              invite.Code,
		Username:                username,
		PasswordHash:            "$argon2id$unused",
		DeviceName:              "phone",
		KeyPackage:              []byte("synthetic-key-package"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := application.Store.CreateSession(ctx, auth.HashToken(token), member.Account.ID, member.Device.ID, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
}

// Shared-address rate limit. People behind one router (one client address)
// each get their own budget once their session resolves, under a ceiling
// for the address; requests without a valid session keep the per-address
// budget, so guessing tokens or credentials from one address is bounded
// exactly as before.
func TestSignedInRequestsUseTheirAccountBudget(t *testing.T) {
	cfg := deploymentConfig(t)
	cfg.RateLimits = config.RateLimits{AddressPerMinute: 5, AccountPerMinute: 5, SignedInAddressPerMinute: 12}
	application, err := New(context.Background(), cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	tokens := map[string]string{"a": "shared-address-token-a-0123456789abcdef"}
	ownerID := ownerSession(t, application, tokens["a"])
	for _, name := range []string{"b", "c"} {
		tokens[name] = "shared-address-token-" + name + "-0123456789abcdef"
		memberSession(t, application, ownerID, "member"+name, tokens[name])
	}
	send := func(address, method, path, token string) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(method, path, strings.NewReader("{}"))
		request.RemoteAddr = address + ":40000"
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder
	}
	expect := func(step string, recorder *httptest.ResponseRecorder, limited bool) {
		t.Helper()
		if (recorder.Code == http.StatusTooManyRequests) != limited {
			t.Fatalf("%s: status=%d, want limited=%v", step, recorder.Code, limited)
		}
		if limited {
			if retry, err := strconv.Atoi(recorder.Header().Get("Retry-After")); err != nil || retry < 1 || retry > 60 {
				t.Fatalf("%s: Retry-After=%q", step, recorder.Header().Get("Retry-After"))
			}
		}
	}
	rejections := func() map[string]int64 {
		out := map[string]int64{}
		for i, scope := range rateLimitScopes {
			out[scope] = application.limiter.rejections[i].Load()
		}
		return out
	}

	// A household: three accounts behind one address, five requests each
	// where the whole address used to get five. The realtime route
	// authenticates outside withAuth and is charged the same way.
	const household = "203.0.113.5"
	for i := 0; i < 4; i++ {
		expect(fmt.Sprintf("a request %d", i+1), send(household, http.MethodGet, "/api/v1/conversations", tokens["a"]), false)
	}
	if code := send(household, http.MethodGet, "/api/v1/sync/ws", tokens["a"]).Code; code == http.StatusTooManyRequests || code == http.StatusUnauthorized {
		t.Fatalf("a's socket request status=%d", code)
	}
	expect("a over its budget", send(household, http.MethodGet, "/api/v1/conversations", tokens["a"]), true)
	if got := rejections()["account"]; got != 1 {
		t.Fatalf("account rejections=%d want 1", got)
	}
	for i := 0; i < 5; i++ {
		expect(fmt.Sprintf("b request %d", i+1), send(household, http.MethodGet, "/api/v1/conversations", tokens["b"]), false)
	}
	// 11 requests with a token so far; the address allows 12 in all.
	expect("c request 1", send(household, http.MethodGet, "/api/v1/conversations", tokens["c"]), false)
	expect("c past the address ceiling", send(household, http.MethodGet, "/api/v1/conversations", tokens["c"]), true)
	if got := rejections()["signed_in"]; got != 1 {
		t.Fatalf("signed-in rejections=%d want 1", got)
	}
	// The same account at another address has its own budget there, as a
	// phone on mobile data did before.
	expect("a at another address", send("198.51.100.77", http.MethodGet, "/api/v1/conversations", tokens["a"]), false)

	// Without a valid session, one address still gets five requests in
	// all: unknown tokens and anonymous requests share that budget, and a
	// valid session from the same address cannot be used to reset it.
	const guesser = "203.0.113.9"
	for i := 0; i < 3; i++ {
		if code := send(guesser, http.MethodGet, "/api/v1/conversations", fmt.Sprintf("guessed-token-%040d", i)).Code; code != http.StatusUnauthorized {
			t.Fatalf("guess %d status=%d want 401", i+1, code)
		}
	}
	expect("signed in beside the guesses", send(guesser, http.MethodGet, "/api/v1/conversations", tokens["b"]), false)
	for i := 3; i < 5; i++ {
		if code := send(guesser, http.MethodGet, "/api/v1/conversations", fmt.Sprintf("guessed-token-%040d", i)).Code; code != http.StatusUnauthorized {
			t.Fatalf("guess %d status=%d want 401", i+1, code)
		}
	}
	expect("sixth guess", send(guesser, http.MethodGet, "/api/v1/conversations", "guessed-token-final-0123456789abcdef"), true)
	expect("anonymous after the guesses", send(guesser, http.MethodGet, "/api/v1/health", ""), true)
	expect("valid session after the guesses", send(guesser, http.MethodGet, "/api/v1/conversations", tokens["c"]), true)

	// Credential routes stay on the address budgets even with a valid
	// session token: a recovery attempt is never moved to the account
	// budget, so five of them use up the address.
	const credential = "203.0.113.11"
	for i := 0; i < 5; i++ {
		expect(fmt.Sprintf("recovery %d", i+1), send(credential, http.MethodGet, "/api/v1/recovery", tokens["c"]), false)
	}
	expect("anonymous after recovery attempts", send(credential, http.MethodGet, "/api/v1/health", ""), true)
	before := rejections()
	expect("sixth recovery", send(credential, http.MethodGet, "/api/v1/recovery", tokens["c"]), true)
	if after := rejections(); after["account"] != before["account"] || after["general"] != before["general"]+1 {
		t.Fatalf("sixth recovery rejected as %v -> %v, want general", before, after)
	}
}

func TestAccountChargeRefundsOnlyItsOwnMinute(t *testing.T) {
	limiter, err := newRateLimiter(nil, rateLimits{general: 2, auth: 1, enrollment: 1, account: 2, signedIn: 10})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	old := &bucket{general: 2, reset: now.Add(-time.Second)}
	current := &bucket{general: 2, reset: now.Add(time.Minute)}
	limiter.buckets[remoteHash(limiter.salt[:], "192.0.2.1")] = current
	charge := &accountCharge{limiter: limiter, host: "192.0.2.1", address: old}
	if ok, _ := charge.Authenticated("acct_x"); !ok {
		t.Fatal("first account request refused")
	}
	if current.general != 2 {
		t.Fatalf("a charge from an earlier minute refunded the current one: general=%d", current.general)
	}
	// A second call (for example withRecentAuth around withAuth) counts once.
	if ok, _ := charge.Authenticated("acct_x"); !ok {
		t.Fatal("repeated call refused")
	}
	if got := limiter.accountBuckets[limiter.accountKey("acct_x", "192.0.2.1")].general; got != 1 {
		t.Fatalf("account count=%d want 1", got)
	}
	if limiter.accountKey("acct_x", "192.0.2.1") == limiter.accountKey("acct_x", "192.0.2.2") ||
		limiter.accountKey("acct_x", "192.0.2.1") == limiter.accountKey("acct_y", "192.0.2.1") {
		t.Fatal("account keys collide across addresses or accounts")
	}
	for _, table := range []map[string]*bucket{limiter.buckets, limiter.accountBuckets} {
		for key := range table {
			if strings.Contains(key, "acct_x") || strings.Contains(key, "192.0.2") {
				t.Fatalf("rate-limit table holds an identifier: %q", key)
			}
		}
	}
}

// Account budgets have their own bounded table: one valid account seen
// from very many addresses (each IPv6 /64 is one) fills only that table,
// and evicting there never resets an address's credential budget.
func TestAccountBucketsCannotEvictAddressBuckets(t *testing.T) {
	limiter, err := newRateLimiter(httpapi.NewClientIdentityResolver(nil), rateLimits{general: 100, auth: 1, enrollment: 1, account: 100, signedIn: 100})
	if err != nil {
		t.Fatal(err)
	}
	handler := limiter.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	login := func() int {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", nil)
		request.RemoteAddr = "192.0.2.50:4000"
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder.Code
	}
	if code := login(); code != http.StatusNoContent {
		t.Fatalf("first login status=%d", code)
	}
	if code := login(); code != http.StatusTooManyRequests {
		t.Fatalf("second login status=%d, want 429", code)
	}
	now := time.Now()
	limiter.mu.Lock()
	for i := 0; i < maxRateLimitEntries; i++ {
		limiter.accountBuckets["filled-"+strconv.Itoa(i)] = &bucket{general: 1, reset: now.Add(time.Minute)}
	}
	addresses := len(limiter.buckets)
	limiter.mu.Unlock()
	// The same account from new /64s: each adds an account bucket, which
	// evicts another account bucket, never an address bucket.
	for i := 0; i < 50; i++ {
		host := rateLimitHost(fmt.Sprintf("2001:db8:%x::1", i))
		if ok, _ := (&accountCharge{limiter: limiter, host: host, address: &bucket{}}).Authenticated("acct_roaming"); !ok {
			t.Fatalf("roaming request %d refused", i)
		}
	}
	limiter.mu.Lock()
	gotAccounts, gotAddresses := len(limiter.accountBuckets), len(limiter.buckets)
	limiter.mu.Unlock()
	if gotAccounts != maxRateLimitEntries || gotAddresses != addresses {
		t.Fatalf("tables: accounts=%d addresses=%d, want %d and %d", gotAccounts, gotAddresses, maxRateLimitEntries, addresses)
	}
	if got := limiter.evictions.Load(); got != 50 {
		t.Fatalf("evictions=%d want 50", got)
	}
	if code := login(); code != http.StatusTooManyRequests {
		t.Fatalf("credential budget was reset under account-table pressure: status=%d", code)
	}
	if entries, _ := limiter.stats(); entries != maxRateLimitEntries+addresses {
		t.Fatalf("stats entries=%d want both tables (%d)", entries, maxRateLimitEntries+addresses)
	}
}
