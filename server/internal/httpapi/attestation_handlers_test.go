package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"private-messenger/server/internal/attest"
)

type fakeProvider struct {
	got    [64]byte
	report []byte
}

func (f *fakeProvider) Kind() string { return "tdx" }
func (f *fakeProvider) Report(_ context.Context, ud [64]byte) (attest.Evidence, error) {
	f.got = ud
	return attest.Evidence{Kind: "tdx", Report: f.report}, nil
}

func attestMux(a *API) *http.ServeMux {
	mux := http.NewServeMux()
	a.Register(mux)
	return mux
}

func TestAttestationRouteIsOffByDefault(t *testing.T) {
	for _, p := range []attest.Provider{nil, attest.None{}} {
		rec := httptest.NewRecorder()
		attestMux(&API{Attest: p, Log: slog.Default()}).ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/attestation?nonce="+strings.Repeat("00", 32), nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("provider %v: status %d, want 404", p, rec.Code)
		}
	}
}

func TestAttestationReturnsReportBoundToNonceAndKey(t *testing.T) {
	fake := &fakeProvider{report: []byte("raw-report-bytes")}
	key := sha256.Sum256([]byte("tls key"))
	var logs bytes.Buffer
	api := &API{Attest: fake, TLSKeyHash: key, ClaimedBuild: ClaimedBuild{Version: "v1", Commit: "abc"}, Log: slog.New(slog.NewTextHandler(&logs, nil))}
	var nonce [32]byte
	nonce[5] = 7
	rec := httptest.NewRecorder()
	attestMux(api).ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/attestation?nonce="+hex.EncodeToString(nonce[:]), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if fake.got != attest.UserData(nonce, key) {
		t.Fatal("provider did not receive the nonce and TLS key hash")
	}
	var body struct {
		Report       string       `json:"report"`
		ClaimedBuild ClaimedBuild `json:"claimed_build"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if raw, _ := base64.StdEncoding.DecodeString(body.Report); !bytes.Equal(raw, fake.report) {
		t.Fatal("report not returned byte for byte")
	}
	if body.ClaimedBuild.Commit != "abc" {
		t.Fatalf("claimed build = %+v", body.ClaimedBuild)
	}
	if out := logs.String(); strings.Contains(out, hex.EncodeToString(nonce[:])) || strings.Contains(out, "raw-report") {
		t.Fatalf("log leaked nonce or report: %s", out)
	}
}

func TestAttestationRejectsBadNonce(t *testing.T) {
	api := &API{Attest: &fakeProvider{}, Log: slog.Default()}
	for _, n := range []string{"", "zz", strings.Repeat("00", 31), strings.Repeat("00", 33)} {
		rec := httptest.NewRecorder()
		attestMux(api).ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/attestation?nonce="+n, nil))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("nonce %q: status %d, want 400", n, rec.Code)
		}
	}
}

type errProvider struct{ err error }

func (e errProvider) Kind() string { return "tdx" }
func (e errProvider) Report(context.Context, [64]byte) (attest.Evidence, error) {
	return attest.Evidence{}, e.err
}

func TestAttestationErrorsLeakNothing(t *testing.T) {
	nonce := "?nonce=" + strings.Repeat("ab", 32)
	for _, tc := range []struct {
		err  error
		code int
	}{{attest.ErrNotConfigured, http.StatusNotFound}, {errors.New("open /sys/kernel/secret-path: denied"), http.StatusServiceUnavailable}} {
		rec := httptest.NewRecorder()
		attestMux(&API{Attest: errProvider{tc.err}, Log: slog.Default()}).ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/attestation"+nonce, nil))
		if rec.Code != tc.code || strings.Contains(rec.Body.String(), "secret-path") {
			t.Fatalf("err %v: status %d body %s", tc.err, rec.Code, rec.Body)
		}
	}
}

func TestAttestationResponseIsNotCached(t *testing.T) {
	rec := httptest.NewRecorder()
	attestMux(&API{Attest: &fakeProvider{}, Log: slog.Default()}).ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/attestation?nonce="+strings.Repeat("01", 32), nil))
	if rec.Code != http.StatusOK || rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("status %d cache %q", rec.Code, rec.Header().Get("Cache-Control"))
	}
}
