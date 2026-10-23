package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
)

// ownerSession creates the owner account with a session and returns its
// bearer token and account ID.
func ownerSession(t *testing.T, application *App, token string) string {
	t.Helper()
	ctx := context.Background()
	reservation, err := application.Store.ReserveOwnerEnrollment(ctx)
	if err != nil {
		t.Fatal(err)
	}
	passwordHash, err := auth.HashPassword("owner-password-123")
	if err != nil {
		t.Fatal(err)
	}
	owner, err := application.Store.CreateOwner(ctx, storage.CreateOwnerInput{
		EnrollmentReservationID: reservation.ID,
		InstanceName:            "Test",
		Username:                "owner",
		PasswordHash:            passwordHash,
		DeviceName:              "owner device",
		KeyPackage:              []byte("synthetic-key-package"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := application.Store.CreateSession(ctx, auth.HashToken(token), owner.Account.ID, owner.Device.ID, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	return owner.Account.ID
}

// A download that a failed integrity check cuts off mid-stream (the handler
// panics with http.ErrAbortHandler) still gets its request log line and
// metrics, marked as aborted, and the client still sees a broken transfer.
func TestAbortedDownloadIsLoggedAndCounted(t *testing.T) {
	ctx := context.Background()
	logs := &lockedBuffer{}
	cfg := deploymentConfig(t)
	application, err := New(ctx, cfg, slog.New(slog.NewTextHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = application.Close() })
	const token = "aborted-download-session-token-0123456789"
	accountID := ownerSession(t, application, token)
	conversation, err := application.Store.CreateConversation(ctx, storage.CreateConversationInput{Kind: "group", CreatedBy: accountID})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(application.Handler())
	defer server.Close()

	payload := bytes.Repeat([]byte{0x5a, 0xa5, 0x3c}, (4*uploads.ChunkSize+100)/3)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/api/v1/attachments?conversation_id="+conversation.ID, bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("X-Private-Messenger-Encrypted", "1")
	request.Header.Set("X-Crypto-Metadata", `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	var attachment struct {
		ID         string `json:"id"`
		StorageKey string `json:"storage_key"`
	}
	if err := json.NewDecoder(response.Body).Decode(&attachment); err != nil || response.StatusCode != http.StatusCreated {
		t.Fatalf("upload status=%d err=%v", response.StatusCode, err)
	}
	response.Body.Close()
	// Damage the third chunk: the first one is verified and sent, then the
	// transfer is aborted.
	blobPath := filepath.Join(cfg.StoragePath, attachment.StorageKey)
	file, err := os.OpenFile(blobPath, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteAt([]byte{0xff}, 2*uploads.ChunkSize+7); err != nil {
		t.Fatal(err)
	}
	file.Close()

	request, err = http.NewRequestWithContext(ctx, http.MethodGet, server.URL+"/api/v1/attachments/"+attachment.ID, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err = http.DefaultClient.Do(request)
	if err == nil {
		_, err = io.Copy(io.Discard, response.Body)
		response.Body.Close()
	}
	if err == nil {
		t.Fatal("aborted download read cleanly")
	}

	var line string
	deadline := time.Now().Add(5 * time.Second)
	for line == "" && time.Now().Before(deadline) {
		for _, candidate := range strings.Split(logs.String(), "\n") {
			if strings.Contains(candidate, "msg=http_request") && strings.Contains(candidate, "outcome=aborted") {
				line = candidate
			}
		}
		if line == "" {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if line == "" {
		t.Fatalf("no aborted request line in the log:\n%s", logs.String())
	}
	for _, want := range []string{`method=GET`, `route=/api/v1/attachments/`, `status=200`, `request_id=`, `duration_ms=`} {
		if !strings.Contains(line, want) {
			t.Fatalf("aborted request line lacks %q: %s", want, line)
		}
	}
	if strings.Contains(line, attachment.ID) || strings.Contains(line, token) {
		t.Fatalf("aborted request line names the attachment or the token: %s", line)
	}
	if !strings.Contains(logs.String(), "blob_integrity_failed") {
		t.Fatal("integrity warning missing")
	}
	if got := strings.Count(logs.String(), "outcome=aborted"); got != 1 {
		t.Fatalf("%d aborted lines, want 1:\n%s", got, logs.String())
	}

	recorder := httptest.NewRecorder()
	application.metrics.handle(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := recorder.Body.String()
	for _, want := range []string{
		"veritra_http_aborted_requests_total 1\n",
		"veritra_http_requests_total 2\n",
		`veritra_http_responses_total{status_class="2xx"} 2` + "\n",
		`veritra_http_route_requests_total{route="/api/v1/attachments/"} 1` + "\n",
		`veritra_http_request_duration_seconds_count{route="/api/v1/attachments/"} 1` + "\n",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("metrics lack %q:\n%s", strings.TrimSpace(want), body)
		}
	}
	if active := application.metrics.active.Load(); active != 0 {
		t.Fatalf("active requests=%d after the abort", active)
	}
}

// A handler that panics before sending anything is logged with status 0
// (nothing reached the client) and counted as aborted but in no status
// class; the panic still reaches net/http with its value.
func TestRequestLoggerRecordsPanicWithoutStatus(t *testing.T) {
	logs := &lockedBuffer{}
	application := &App{Log: slog.New(slog.NewTextHandler(logs, nil)), metrics: newHTTPMetrics()}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/boom", func(http.ResponseWriter, *http.Request) {
		panic(http.ErrAbortHandler)
	})
	handler := application.requestLogger(routeTimeouts(mux))
	func() {
		defer func() {
			if recovered := recover(); recovered != http.ErrAbortHandler {
				t.Fatalf("panic value %v did not reach the caller", recovered)
			}
		}()
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/v1/boom", nil))
	}()
	output := logs.String()
	if !strings.Contains(output, `route="GET /api/v1/boom"`) || !strings.Contains(output, "status=0") || !strings.Contains(output, "outcome=aborted") {
		t.Fatalf("aborted request line: %s", output)
	}
	if application.metrics.aborted.Load() != 1 || application.metrics.total.Load() != 1 {
		t.Fatalf("aborted=%d total=%d", application.metrics.aborted.Load(), application.metrics.total.Load())
	}
	for class := 1; class <= 5; class++ {
		if n := application.metrics.statusClass[class].Load(); n != 0 {
			t.Fatalf("status class %dxx counted %d", class, n)
		}
	}

	// A normal request has no outcome attribute.
	logs.mu.Lock()
	logs.buf.Reset()
	logs.mu.Unlock()
	mux.HandleFunc("GET /api/v1/fine", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/v1/fine", nil))
	if output := logs.String(); strings.Contains(output, "outcome") || !strings.Contains(output, "status=204") {
		t.Fatalf("normal request line: %s", output)
	}
}
