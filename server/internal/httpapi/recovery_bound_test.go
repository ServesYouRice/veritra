package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"net/http"
	"testing"
)

// VAL-215 (audit plan Q-004 option (a)): a token holder repeatedly range-reading
// almost the whole blob (size-1 bytes) cannot do so indefinitely without consuming
// the capability. Once total bytes served reaches the bound (2x size), the capability
// is consumed and subsequent reads are refused (404 Not Found).
func TestRecoveryRepeatedRangeReadsConsumeAtBound(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	payload := []byte("0123456789abcdefghijklmnopqrstuvwxyz") // 36 bytes
	size := int64(len(payload))
	recoveryToken := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))

	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/backups", token, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
		"X-Recovery-Token":              recoveryToken,
	})
	if status != http.StatusCreated {
		t.Fatalf("create backup status=%d body=%s", status, response)
	}

	rangeHeader := fmt.Sprintf("bytes=0-%d", size-2) // size - 1 bytes (35 bytes)
	getRange := func() (int, []byte) {
		return doRaw(t, handler, http.MethodGet, "/api/v1/recovery", "", nil, map[string]string{
			"X-Recovery-Token": recoveryToken,
			"Range":            rangeHeader,
		})
	}

	// Repeatedly read size-1 bytes. Under the cap (2 * size = 72 bytes):
	// Attempt 1: 35 bytes served (total 35 < 72).
	// Attempt 2: 35 bytes served (total 70 < 72).
	// Attempt 3: 35 bytes served (total 105 >= 72) -> consumed at bound.
	// Attempt 4+: refused with 404 (capability consumed).
	consumed := false
	const maxAttempts = 10
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		statusCode, body := getRange()
		if statusCode == http.StatusNotFound {
			consumed = true
			if attempt < 3 {
				t.Fatalf("consumed too early on attempt %d", attempt)
			}
			break
		}
		if statusCode != http.StatusPartialContent || int64(len(body)) != size-1 {
			t.Fatalf("attempt %d: unexpected status %d len %d", attempt, statusCode, len(body))
		}
	}
	if !consumed {
		t.Fatalf("capability was not consumed after %d attempts of size-1 range reads", maxAttempts)
	}
}

// VAL-215: A legitimate recovery download interrupted mid-stream and resumed
// completes successfully, and consumes the capability upon reaching the end.
func TestRecoveryLegitimateResumeAfterInterruption(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	payload := []byte("0123456789abcdefghijklmnopqrstuvwxyz") // 36 bytes
	recoveryToken := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{11}, 32))

	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/backups", token, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
		"X-Recovery-Token":              recoveryToken,
	})
	if status != http.StatusCreated {
		t.Fatalf("create backup status=%d body=%s", status, response)
	}

	get := func(rangeHeader string) (int, []byte) {
		headers := map[string]string{"X-Recovery-Token": recoveryToken}
		if rangeHeader != "" {
			headers["Range"] = rangeHeader
		}
		return doRaw(t, handler, http.MethodGet, "/api/v1/recovery", "", nil, headers)
	}

	// 1. First partial read (0-19)
	status, body := get("bytes=0-19")
	if status != http.StatusPartialContent || !bytes.Equal(body, payload[:20]) {
		t.Fatalf("initial part status=%d body=%q", status, body)
	}

	// 2. Resume from 15 to the end
	status, body = get("bytes=15-")
	if status != http.StatusPartialContent || !bytes.Equal(body, payload[15:]) {
		t.Fatalf("resumed part status=%d body=%q", status, body)
	}

	// 3. Capability was consumed upon reaching the end
	status, _ = get("")
	if status != http.StatusNotFound {
		t.Fatalf("re-read after completion status=%d, want 404", status)
	}
}

// Empty backup recovery succeeds on its first download and is consumed on completion.
func TestRecoveryEmptyBlobSucceedsAndConsumes(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	payload := []byte{}
	recoveryToken := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{13}, 32))

	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/backups", token, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
		"X-Recovery-Token":              recoveryToken,
	})
	if status != http.StatusCreated {
		t.Fatalf("create backup status=%d body=%s", status, response)
	}

	get := func() (int, []byte) {
		return doRaw(t, handler, http.MethodGet, "/api/v1/recovery", "", nil, map[string]string{
			"X-Recovery-Token": recoveryToken,
		})
	}

	// 1. First download succeeds
	status, body := get()
	if status != http.StatusOK || len(body) != 0 {
		t.Fatalf("download status=%d body=%q, want 200 and empty", status, body)
	}

	// 2. Capability was consumed
	status, _ = get()
	if status != http.StatusNotFound {
		t.Fatalf("re-read after completion status=%d, want 404", status)
	}
}
