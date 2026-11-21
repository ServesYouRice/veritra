package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
)

// The app ends its session on a 401 (it clears cached state and asks the
// person to sign in again). A session lookup that fails for any reason other
// than "no such, expired or revoked session" must therefore never answer
// 401: under overload a busy or timed-out database signed people out.

type sessionLookupFixture struct {
	api       *API
	logs      *bytes.Buffer
	token     string
	tokenHash string
	reached   *bool
}

func newSessionLookupFixture(t *testing.T) sessionLookupFixture {
	t.Helper()
	api, principal, _ := newPushTestAPI(t, "fcm")
	logs := &bytes.Buffer{}
	api.Log = slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := api.Store.CreateSession(context.Background(), tokenHash, principal.AccountID, principal.DeviceID, time.Time{}); err != nil {
		t.Fatal(err)
	}
	return sessionLookupFixture{api: api, logs: logs, token: token, tokenHash: tokenHash, reached: new(bool)}
}

// withAuthHandler wraps a handler that only records that it ran.
func (f sessionLookupFixture) withAuthHandler() http.HandlerFunc {
	return f.api.withAuth(func(w http.ResponseWriter, _ *http.Request, _ domain.Principal) {
		*f.reached = true
		w.WriteHeader(http.StatusNoContent)
	})
}

func serveWithToken(handler http.Handler, ctx context.Context, token string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, "/", nil).WithContext(ctx)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func errorCode(t *testing.T, recorder *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("error body %q: %v", recorder.Body.String(), err)
	}
	return body.Error
}

func assertSessionCheckUnavailable(t *testing.T, recorder *httptest.ResponseRecorder) {
	t.Helper()
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s, want 503 (never 401 for a storage failure)", recorder.Code, recorder.Body.String())
	}
	if code := errorCode(t, recorder); code != "session_check_unavailable" {
		t.Fatalf("error=%q, want session_check_unavailable", code)
	}
	if recorder.Header().Get("Retry-After") == "" {
		t.Fatal("503 without Retry-After")
	}
}

func (f sessionLookupFixture) assertNoSecretsLogged(t *testing.T) {
	t.Helper()
	logged := f.logs.String()
	if strings.Contains(logged, f.token) || strings.Contains(logged, f.tokenHash) {
		t.Fatalf("log carries the token or its hash: %s", logged)
	}
}

func TestWithAuthStorageFailureAnswers503NotUnauthorized(t *testing.T) {
	f := newSessionLookupFixture(t)
	handler := f.withAuthHandler()
	if got := serveWithToken(handler, context.Background(), f.token); got.Code != http.StatusNoContent {
		t.Fatalf("valid session before the failure: status=%d", got.Code)
	}
	*f.reached = false
	if err := f.api.Store.Close(); err != nil {
		t.Fatal(err)
	}

	recorder := serveWithToken(handler, context.Background(), f.token)
	assertSessionCheckUnavailable(t, recorder)
	if *f.reached {
		t.Fatal("handler ran without a validated session")
	}
	if !strings.Contains(f.logs.String(), "session_lookup_failed") {
		t.Fatalf("storage failure not logged: %q", f.logs.String())
	}
	f.assertNoSecretsLogged(t)
}

func TestWithAuthUnknownOrRevokedSessionStillUnauthorized(t *testing.T) {
	f := newSessionLookupFixture(t)
	handler := f.withAuthHandler()
	unknown, _, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	if got := serveWithToken(handler, context.Background(), unknown); got.Code != http.StatusUnauthorized || errorCode(t, got) != "unauthorized" {
		t.Fatalf("unknown token: status=%d body=%s", got.Code, got.Body.String())
	}
	if err := f.api.Store.DeleteSession(context.Background(), f.tokenHash); err != nil {
		t.Fatal(err)
	}
	if got := serveWithToken(handler, context.Background(), f.token); got.Code != http.StatusUnauthorized || errorCode(t, got) != "unauthorized" {
		t.Fatalf("deleted session: status=%d body=%s", got.Code, got.Body.String())
	}
	if *f.reached {
		t.Fatal("handler ran for a rejected session")
	}
	if strings.Contains(f.logs.String(), "session_lookup_failed") {
		t.Fatalf("a rejected session was logged as a storage failure: %q", f.logs.String())
	}
}

func TestWithAuthCancelledRequestIsNotUnauthorizedAndNotLogged(t *testing.T) {
	f := newSessionLookupFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	recorder := serveWithToken(f.withAuthHandler(), ctx, f.token)
	assertSessionCheckUnavailable(t, recorder)
	if *f.reached {
		t.Fatal("handler ran for a cancelled request")
	}
	if strings.Contains(f.logs.String(), "session_lookup_failed") {
		t.Fatalf("a client cancellation was logged as a failure: %q", f.logs.String())
	}
}

func TestWithAuthLookupTimeoutAnswers503AndIsLogged(t *testing.T) {
	f := newSessionLookupFixture(t)
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()

	recorder := serveWithToken(f.withAuthHandler(), ctx, f.token)
	assertSessionCheckUnavailable(t, recorder)
	if !strings.Contains(f.logs.String(), "session_lookup_failed") {
		t.Fatalf("lookup timeout not logged: %q", f.logs.String())
	}
	f.assertNoSecretsLogged(t)
}

// authenticate serves the routes outside withAuth: the realtime upgrade and
// the device-link reads and approvals.
func TestAuthenticateStorageFailureAnswers503NotUnauthorized(t *testing.T) {
	f := newSessionLookupFixture(t)
	if err := f.api.Store.Close(); err != nil {
		t.Fatal(err)
	}
	for name, handler := range map[string]http.HandlerFunc{
		"sync websocket": f.api.syncWebSocket,
		"device link":    f.api.deviceLinkSubroute,
	} {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/api/v1/device-links/some-link", nil)
			request.Header.Set("Authorization", "Bearer "+f.token)
			recorder := httptest.NewRecorder()
			handler(recorder, request)
			assertSessionCheckUnavailable(t, recorder)
		})
	}
	f.assertNoSecretsLogged(t)
}

func TestAuthenticateUnknownSessionStillUnauthorized(t *testing.T) {
	f := newSessionLookupFixture(t)
	unknown, _, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Authorization", "Bearer "+unknown)
	recorder := httptest.NewRecorder()
	f.api.syncWebSocket(recorder, request)
	if recorder.Code != http.StatusUnauthorized || errorCode(t, recorder) != "unauthorized" {
		t.Fatalf("unknown token on the realtime upgrade: status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}
