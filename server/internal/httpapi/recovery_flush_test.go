package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

// flushFailingWriter is a ResponseWriter whose connection "drops": the n-th
// FlushError (1-based) and every later one fails, as a flush to a closed
// socket does. Writes keep succeeding into the buffer, as they do on the real
// server until the buffer is flushed.
type flushFailingWriter struct {
	header   http.Header
	status   int
	body     bytes.Buffer
	failFrom int
	flushes  int
}

func (w *flushFailingWriter) Header() http.Header { return w.header }
func (w *flushFailingWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}
func (w *flushFailingWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.body.Write(p)
}
func (w *flushFailingWriter) FlushError() error {
	w.flushes++
	if w.flushes >= w.failFrom {
		return errors.New("connection lost")
	}
	return nil
}

// Recovery progress counts only bytes a flush confirmed. A transfer whose
// final flush fails must not consume the one-time capability, so the client
// can fetch again (VAL-229). Whether the bytes then reached the client is the
// open acknowledgement question; a successful flush only reaches the kernel.
func TestRecoveryCapabilitySurvivesFailedFinalFlush(t *testing.T) {
	for _, tc := range []struct {
		name     string
		size     int
		failFrom int
	}{
		{"final flush fails", 4096, 1},
		{"later flush fails after a confirmed one", 3<<20 + 123, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			handler, token, _ := newTestHandlerWithOwner(t)
			payload := bytes.Repeat([]byte("recovery-payload-"), tc.size/17+1)[:tc.size]
			recoveryToken := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{5}, 32))
			status, response := doRaw(t, handler, http.MethodPost, "/api/v1/backups", token, payload, map[string]string{
				"X-Private-Messenger-Encrypted": "1",
				"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
				"X-Recovery-Token":              recoveryToken,
			})
			if status != http.StatusCreated {
				t.Fatalf("backup status=%d body=%s", status, response)
			}

			request := httptest.NewRequest(http.MethodGet, "/api/v1/recovery", nil)
			request.Header.Set("X-Recovery-Token", recoveryToken)
			failing := &flushFailingWriter{header: http.Header{}, failFrom: tc.failFrom}
			handler.ServeHTTP(failing, request)
			if failing.flushes == 0 {
				t.Fatal("the server never flushed a recovery response, so it cannot know what was delivered")
			}

			// The capability survived: the same token still downloads everything.
			status, response = doRaw(t, handler, http.MethodGet, "/api/v1/recovery", "", nil, map[string]string{"X-Recovery-Token": recoveryToken})
			if status != http.StatusOK || !bytes.Equal(response, payload) {
				t.Fatalf("retry after a failed flush: status=%d, %d of %d bytes", status, len(response), len(payload))
			}
			// That complete transfer consumed it.
			if status, _ = doRaw(t, handler, http.MethodGet, "/api/v1/recovery", "", nil, map[string]string{"X-Recovery-Token": recoveryToken}); status != http.StatusNotFound {
				t.Fatalf("capability not consumed by a complete flushed transfer: status=%d", status)
			}
		})
	}
}
