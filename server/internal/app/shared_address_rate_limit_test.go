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
	// valid session from the same address cannot be used to reset it. But
	// they no longer refuse the valid sessions there.
	const guesser = "203.0.113.9"
	guess := func(i int) *httptest.ResponseRecorder {
		return send(guesser, http.MethodGet, "/api/v1/conversations", fmt.Sprintf("guessed-token-%040d", i))
	}
	for i := 0; i < 3; i++ {
		if code := guess(i).Code; code != http.StatusUnauthorized {
			t.Fatalf("guess %d status=%d want 401", i+1, code)
		}
	}
	expect("signed in beside the guesses", send(guesser, http.MethodGet, "/api/v1/conversations", tokens["b"]), false)
	for i := 3; i < 5; i++ {
		if code := guess(i).Code; code != http.StatusUnauthorized {
			t.Fatalf("guess %d status=%d want 401", i+1, code)
		}
	}
	before := rejections()
	expect("sixth guess", guess(5), true)
	if after := rejections(); after["general"] != before["general"]+1 {
		t.Fatalf("sixth guess rejected as %v -> %v, want general", before, after)
	}
	expect("anonymous after the guesses", send(guesser, http.MethodGet, "/api/v1/health", ""), true)
	expect("valid session after the guesses", send(guesser, http.MethodGet, "/api/v1/conversations", tokens["c"]), false)
	// Token lookups from one address stay bounded by its signed-in
	// ceiling (12): 8 token requests so far, 4 more guesses fill it, and
	// then any token is refused before it is looked up.
	for i := 6; i < 10; i++ {
		expect(fmt.Sprintf("guess %d past the general budget", i+1), guess(i), true)
	}
	before = rejections()
	expect("guess past the signed-in ceiling", guess(10), true)
	expect("valid session past the signed-in ceiling", send(guesser, http.MethodGet, "/api/v1/conversations", tokens["c"]), true)
	if after := rejections(); after["signed_in"] != before["signed_in"]+2 || after["general"] != before["general"] {
		t.Fatalf("ceiling rejections %v -> %v, want two signed_in", before, after)
	}

	// The review case: a device whose session expired retries in a loop
	// behind a shared address. It uses up the address's budget for
	// requests without a session, and is refused with Retry-After once it
	// has, but its signed-in neighbours keep their own budgets.
	const neighbours = "203.0.113.12"
	for i := 0; i < 8; i++ {
		code := send(neighbours, http.MethodGet, "/api/v1/sync/events", "expired-session-token-0123456789abcdef").Code
		if want := map[bool]int{true: http.StatusUnauthorized, false: http.StatusTooManyRequests}[i < 5]; code != want {
			t.Fatalf("expired retry %d status=%d want %d", i+1, code, want)
		}
	}
	for _, name := range []string{"a", "b"} {
		expect(name+" beside the retry loop", send(neighbours, http.MethodGet, "/api/v1/conversations", tokens[name]), false)
	}
	expect("signed-out neighbour beside the retry loop", send(neighbours, http.MethodGet, "/api/v1/health", ""), true)

	// A token on a route that never looks it up is admitted on the
	// signed-in ceiling and charged as a request without a session once
	// served: it cannot add to the address's budget for those.
	const junk = "203.0.113.13"
	for i := 0; i < 5; i++ {
		expect(fmt.Sprintf("junk token on a public route %d", i+1), send(junk, http.MethodGet, "/api/v1/health", "junk-token-0123456789abcdef0123"), false)
	}
	expect("anonymous after junk tokens", send(junk, http.MethodGet, "/api/v1/health", ""), true)

	// Credential routes stay on the address budgets even with a valid
	// session token: a recovery attempt is never moved to the account
	// budget, so five of them use up the address.
	const credential = "203.0.113.11"
	for i := 0; i < 5; i++ {
		expect(fmt.Sprintf("recovery %d", i+1), send(credential, http.MethodGet, "/api/v1/recovery", tokens["c"]), false)
	}
	expect("anonymous after recovery attempts", send(credential, http.MethodGet, "/api/v1/health", ""), true)
	before = rejections()
	expect("sixth recovery", send(credential, http.MethodGet, "/api/v1/recovery", tokens["c"]), true)
	if after := rejections(); after["account"] != before["account"] || after["general"] != before["general"]+1 {
		t.Fatalf("sixth recovery rejected as %v -> %v, want general", before, after)
	}
}

// A route that never looks a token up stays on the address's general
// budget: any Authorization header there would otherwise buy the larger
// signed-in budget for health and setup requests, each of which touches
// the disk.
func TestPublicRoutesIgnoreBearerTokens(t *testing.T) {
	cfg := deploymentConfig(t)
	cfg.RateLimits = config.RateLimits{AddressPerMinute: 60, AccountPerMinute: 60, SignedInAddressPerMinute: 300}
	application, err := New(context.Background(), cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	for _, path := range []string{"/livez", "/api/v1/health", "/api/v1/setup/status"} {
		address := "203.0.113." + strconv.Itoa(len(path))
		served := 0
		for i := 0; i < 70; i++ {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			request.RemoteAddr = address + ":40000"
			request.Header.Set("Authorization", "Bearer junk-token-"+strconv.Itoa(i))
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)
			if recorder.Code == http.StatusTooManyRequests {
				break
			}
			served++
		}
		if served != 60 {
			t.Fatalf("%s served %d junk-token requests from one address, want the general 60", path, served)
		}
	}
}

func TestAccountChargeSettlesOnce(t *testing.T) {
	limiter, err := newRateLimiter(nil, rateLimits{general: 2, auth: 1, enrollment: 1, account: 2, signedIn: 10})
	if err != nil {
		t.Fatal(err)
	}
	address := func() int {
		if b := limiter.buckets[remoteHash(limiter.salt[:], "192.0.2.1")]; b != nil {
			return b.general
		}
		return 0
	}
	charge := &accountCharge{limiter: limiter, host: "192.0.2.1"}
	if ok, _ := charge.Authenticated("acct_x"); !ok {
		t.Fatal("first account request refused")
	}
	// A second call (for example withRecentAuth around withAuth) counts
	// once, and nothing later moves a settled request.
	if ok, _ := charge.Authenticated("acct_x"); !ok {
		t.Fatal("repeated call refused")
	}
	charge.settleUnused()
	if ok, _ := charge.Unauthenticated(); !ok {
		t.Fatal("unauthenticated after authenticated changed the outcome")
	}
	if got := limiter.accountBuckets[limiter.accountKey("acct_x", "192.0.2.1")].general; got != 1 {
		t.Fatalf("account count=%d want 1", got)
	}
	if got := address(); got != 0 {
		t.Fatalf("a valid session was charged to the address: general=%d", got)
	}
	// Tokens that do not resolve, and tokens a route never looked up,
	// go to the address's general budget for the current minute.
	unresolved := &accountCharge{limiter: limiter, host: "192.0.2.1"}
	if ok, _ := unresolved.Unauthenticated(); !ok {
		t.Fatal("first unresolved token refused")
	}
	(&accountCharge{limiter: limiter, host: "192.0.2.1"}).settleUnused()
	if got := address(); got != 2 {
		t.Fatalf("address general=%d want 2", got)
	}
	before := limiter.rejections[scopeGeneral].Load()
	(&accountCharge{limiter: limiter, host: "192.0.2.1"}).settleUnused()
	if got := limiter.rejections[scopeGeneral].Load(); got != before {
		t.Fatal("a request already served was counted as refused")
	}
	if ok, retry := (&accountCharge{limiter: limiter, host: "192.0.2.1"}).Unauthenticated(); ok || retry < 1 || retry > 60 {
		t.Fatalf("unresolved token past the general budget: ok=%v retry=%d", ok, retry)
	}
	if got := limiter.rejections[scopeGeneral].Load(); got != before+1 {
		t.Fatalf("general rejections=%d want %d", got, before+1)
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
	// The same account from new /64s: each finds the account table full of
	// live buckets and is charged to the overflow bucket; no bucket is evicted.
	for i := 0; i < 50; i++ {
		host := rateLimitHost(fmt.Sprintf("2001:db8:%x::1", i))
		if ok, _ := (&accountCharge{limiter: limiter, host: host}).Authenticated("acct_roaming"); !ok {
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
