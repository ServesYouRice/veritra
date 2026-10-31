package httpapi_test

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"private-messenger/server/internal/httpapi"
)

// startPausedRecovery uploads a backup and starts its recovery download. The
// client reads a little and then stops, so the server blocks in Write with the
// lease held.
func startPausedRecovery(t *testing.T, handler http.Handler, token, dbPath string, seed byte) (*http.Response, *sql.DB, string, []byte) {
	t.Helper()
	payload := blobTestPayload(64 * chunk) // 4 MiB: more than the socket buffers hold
	recoveryToken := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{seed}, 32))
	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/backups", token, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
		"X-Recovery-Token":              recoveryToken,
	})
	if status != http.StatusCreated {
		t.Fatalf("backup status=%d body=%s", status, response)
	}
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	request, err := http.NewRequest(http.MethodGet, server.URL+"/api/v1/recovery", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Recovery-Token", recoveryToken)
	resp, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("recovery status=%d", resp.StatusCode)
	}
	if _, err := io.ReadFull(resp.Body, make([]byte, 100)); err != nil {
		t.Fatalf("read start of the stream: %v", err)
	}
	db, err := sql.Open("sqlite", "file:"+dbPath+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return resp, db, recoveryToken, payload
}

func recoveryLeaseExpiry(t *testing.T, db *sql.DB) string {
	t.Helper()
	var expiry sql.NullString
	if err := db.QueryRow(`SELECT recovery_lease_expires_at FROM backup_blobs`).Scan(&expiry); err != nil {
		t.Fatal(err)
	}
	return expiry.String
}

func TestRecoveryStreamRenewsItsLease(t *testing.T) {
	defer httpapi.SetRecoveryLeaseRenewIntervalForTest(20 * time.Millisecond)()
	handler, token, dbPath := newTestHandlerWithOwner(t)
	resp, db, _, payload := startPausedRecovery(t, handler, token, dbPath, 0x41)

	before := recoveryLeaseExpiry(t, db)
	if before == "" {
		t.Fatal("no lease held while the stream is open")
	}
	deadline := time.Now().Add(5 * time.Second)
	for recoveryLeaseExpiry(t, db) == before {
		if time.Now().After(deadline) {
			t.Fatal("the lease was not renewed while the stream was open")
		}
		time.Sleep(10 * time.Millisecond)
	}
	rest, err := io.ReadAll(resp.Body)
	if err != nil || len(rest) != len(payload)-100 {
		t.Fatalf("rest of the stream: %d bytes, err = %v, want %d", len(rest), err, len(payload)-100)
	}
	var tokenHash []byte
	var next int64
	if err := db.QueryRow(`SELECT recovery_token_hash, recovery_next_offset FROM backup_blobs`).Scan(&tokenHash, &next); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(5 * time.Second)
	for tokenHash != nil && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
		if err := db.QueryRow(`SELECT recovery_token_hash, recovery_next_offset FROM backup_blobs`).Scan(&tokenHash, &next); err != nil {
			t.Fatal(err)
		}
	}
	if tokenHash != nil || next != int64(len(payload)) {
		t.Fatalf("after a complete stream: token hash = %x, offset = %d, want a consumed capability at %d", tokenHash, next, len(payload))
	}
}

func TestRecoveryStreamStopsWhenItsLeaseIsTakenOver(t *testing.T) {
	defer httpapi.SetRecoveryLeaseRenewIntervalForTest(20 * time.Millisecond)()
	handler, token, dbPath := newTestHandlerWithOwner(t)
	resp, db, _, payload := startPausedRecovery(t, handler, token, dbPath, 0x42)

	// Another caller now holds the lease; the paused stream's next renewal
	// fails and its writer must stop.
	if _, err := db.Exec(`UPDATE backup_blobs SET recovery_lease_id = 'recovery_lease_taken_over'`); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	rest, err := io.ReadAll(resp.Body)
	if err == nil && len(rest) == len(payload)-100 {
		t.Fatal("the stream ran to the end after its lease was taken over")
	}
	var tokenHash []byte
	if err := db.QueryRow(`SELECT recovery_token_hash FROM backup_blobs`).Scan(&tokenHash); err != nil {
		t.Fatal(err)
	}
	if tokenHash == nil {
		t.Fatal("the capability was consumed by a stream that lost its lease")
	}
}
