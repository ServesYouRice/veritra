package httpapi

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Card I37: the setup token is compared through fixed-size SHA-256 digests,
// so only the exact token passes, whatever the length or prefix of the
// candidate. Timing is not measured here; the constant-time property comes
// from subtle.ConstantTimeCompare over two 32-byte digests.
func TestSetupTokenAcceptsOnlyTheExactToken(t *testing.T) {
	raw := make([]byte, 32)
	for i := range raw {
		raw[i] = byte(i*7 + 3)
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	api := &API{SetupToken: token, ClientIdentities: NewClientIdentityResolver(nil)}
	authorized := func(candidate string, set bool) bool {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/setup/owner", nil)
		request.RemoteAddr = "127.0.0.1:8080"
		if set {
			request.Header.Set("X-Veritra-Setup-Token", candidate)
		}
		return api.setupAuthorized(request)
	}
	if !authorized(token, true) {
		t.Fatal("exact setup token rejected")
	}
	for name, candidate := range map[string]string{
		"empty":            "",
		"prefix":           token[:len(token)-1],
		"one byte":         token[:1],
		"extension":        token + "A",
		"doubled":          token + token,
		"case changed":     strings.ToUpper(token[:1]) + strings.ToLower(token[1:]),
		"last byte":        token[:len(token)-1] + string(token[len(token)-1]^1),
		"padded":           token + "=",
		"surrounding text": " " + token,
		"64 KiB":           strings.Repeat(token, 2048),
	} {
		if candidate == token {
			continue
		}
		if authorized(candidate, true) {
			t.Fatalf("%s setup token candidate accepted", name)
		}
	}
	if authorized("", false) {
		t.Fatal("missing setup token header accepted from loopback")
	}
}
