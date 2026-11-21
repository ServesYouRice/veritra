package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// C6 report keys: a publish names the key the device saw listed (or none),
// and the server publishes only while that is still the current key. One
// device of an account must never overwrite a key another device published
// meanwhile (docs/designs/C6-reports-franking.md, "Seed replacement").
func TestReportKeyPublishIsCompareAndSwap(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, response)
	}
	var community struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &community); err != nil {
		t.Fatal(err)
	}
	for name, path := range map[string]string{
		"instance":  "/api/v1/reports/inbox-keys/instance",
		"community": "/api/v1/reports/inbox-keys/community/" + community.ID,
	} {
		t.Run(name, func(t *testing.T) {
			key1, key2, key3 := bytes.Repeat([]byte{11}, 32), bytes.Repeat([]byte{12}, 32), bytes.Repeat([]byte{13}, 32)
			listed := func(want []byte, rev string) {
				t.Helper()
				status, response := doJSON(t, handler, http.MethodGet, path, ownerToken, nil)
				if status != http.StatusOK || !strings.Contains(string(response), base64.StdEncoding.EncodeToString(want)) || !strings.Contains(string(response), `"key_rev":`+rev) {
					t.Fatalf("listed key status=%d body=%s, want rev %s", status, response, rev)
				}
			}
			conflict := func(what string, status int, body string) {
				t.Helper()
				if status != http.StatusConflict || !strings.Contains(body, `"report_key_changed"`) {
					t.Fatalf("%s status=%d body=%s, want 409 report_key_changed", what, status, body)
				}
			}
			// Expecting a key while none is published is refused.
			status, body := replaceReportKey(t, handler, path, ownerToken, key1, key2)
			conflict("first publish expecting a key", status, body)
			// A first publish with no expectation (an app from before the
			// field, which sends none) works, and so does the same key again.
			for _, attempt := range []string{"first", "same again"} {
				status, response := doJSON(t, handler, http.MethodPut, path, ownerToken, map[string]interface{}{"public_key": base64.StdEncoding.EncodeToString(key1)})
				if status != http.StatusOK || !strings.Contains(string(response), `"key_rev":1`) {
					t.Fatalf("%s publish without expectation status=%d body=%s", attempt, status, response)
				}
			}
			listed(key1, "1")
			// Device B saw key1 and replaces it.
			if status, body := replaceReportKey(t, handler, path, ownerToken, key2, key1); status != http.StatusOK || !strings.Contains(body, `"key_rev":2`) {
				t.Fatalf("replace with the listed key status=%d body=%s", status, body)
			}
			// Device A also saw key1: its replace is refused, B's key stays.
			status, body = replaceReportKey(t, handler, path, ownerToken, key3, key1)
			conflict("stale replace", status, body)
			listed(key2, "2")
			// No expectation, or an explicit "none", never replaces a key.
			status, response := doJSON(t, handler, http.MethodPut, path, ownerToken, map[string]interface{}{"public_key": base64.StdEncoding.EncodeToString(key3)})
			conflict("replace without expectation", status, string(response))
			status, body = replaceReportKey(t, handler, path, ownerToken, key3, nil)
			conflict("replace expecting none", status, body)
			listed(key2, "2")
			// Republishing the current key changes nothing, whatever was
			// expected: a retry after a lost response still succeeds.
			if status, body := replaceReportKey(t, handler, path, ownerToken, key2, key1); status != http.StatusOK || !strings.Contains(body, `"key_rev":2`) {
				t.Fatalf("same-key retry with a stale expectation status=%d body=%s", status, body)
			}
			// A malformed expectation is a bad request.
			status, response = doJSON(t, handler, http.MethodPut, path, ownerToken, map[string]interface{}{
				"public_key": base64.StdEncoding.EncodeToString(key3), "expected_public_key": base64.StdEncoding.EncodeToString(key2[:31]),
			})
			if status != http.StatusBadRequest || !strings.Contains(string(response), "invalid_public_key") {
				t.Fatalf("short expectation status=%d body=%s", status, response)
			}
			listed(key2, "2")
		})
	}
}
