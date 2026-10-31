package httpapi_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"private-messenger/server/internal/uploads"
)

const chunk = uploads.ChunkSize

// T49B miss 6: a range request verifies only the chunks it serves. A bad
// chunk at the start of a response is a clean 500; one found later aborts
// the transfer, so a client never receives an unverified byte.
func TestAttachmentRangeVerifiesOnlyServedChunks(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	payload := blobTestPayload(4*chunk + 100)
	id, path := uploadTestAttachment(t, handler, token, dbPath, payload)
	flipBlobByte(t, path, 2*chunk+7)
	url := "/api/v1/attachments/" + id

	for _, r := range []struct{ start, end int }{{0, 2*chunk - 1}, {3 * chunk, 3*chunk + 99}, {4 * chunk, 4*chunk + 99}} {
		rec := getBlob(handler, url, token, fmt.Sprintf("bytes=%d-%d", r.start, r.end))
		if rec.Code != http.StatusPartialContent || !bytes.Equal(rec.Body.Bytes(), payload[r.start:r.end+1]) {
			t.Fatalf("range %d-%d: status=%d len=%d", r.start, r.end, rec.Code, rec.Body.Len())
		}
	}
	rec := getBlob(handler, url, token, fmt.Sprintf("bytes=%d-", 2*chunk+5))
	if rec.Code != http.StatusInternalServerError || !bytes.Contains(rec.Body.Bytes(), []byte("blob_integrity_failed")) ||
		rec.Header().Get("Content-Range") != "" || rec.Header().Get("Etag") != "" {
		t.Fatalf("range in bad chunk: status=%d headers=%v body=%q", rec.Code, rec.Header(), rec.Body.Bytes())
	}
	// Several ranges are refused: each would cost a seek and a chunk
	// verification (see TestBlobDownloadRejectsMultiRange).
	rec = getBlob(handler, url, token, fmt.Sprintf("bytes=0-9,%d-%d", 3*chunk, 3*chunk+9))
	if rec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("multi-range status=%d, want 416", rec.Code)
	}

	server := httptest.NewServer(handler)
	defer server.Close()
	for _, rangeHeader := range []string{"", "bytes=10-", fmt.Sprintf("bytes=0-%d", 2*chunk+9)} {
		status, body, err := fetchBlob(t, server.URL+url, token, rangeHeader)
		if status != 0 && status != http.StatusOK && status != http.StatusPartialContent {
			t.Fatalf("range %q: status=%d", rangeHeader, status)
		}
		if err == nil {
			t.Fatalf("range %q: aborted transfer read cleanly (%d bytes)", rangeHeader, len(body))
		}
		if rangeHeader == "" && (len(body) > 2*chunk || !bytes.Equal(body, payload[:len(body)])) {
			t.Fatalf("full download returned %d bytes that are not a verified prefix", len(body))
		}
		if rangeHeader == "bytes=10-" && (len(body) > 2*chunk-10 || !bytes.Equal(body, payload[10:10+len(body)])) {
			t.Fatalf("open range returned %d bytes that are not a verified prefix", len(body))
		}
		if bytes.Contains(body, payload[2*chunk:2*chunk+7]) {
			t.Fatalf("range %q: bytes from the bad chunk were sent", rangeHeader)
		}
	}

	// A truncated file fails before any byte, as before.
	if err := os.Truncate(path, int64(len(payload)-1)); err != nil {
		t.Fatal(err)
	}
	rec = getBlob(handler, url, token, "bytes=0-9")
	if rec.Code != http.StatusInternalServerError || !bytes.Contains(rec.Body.Bytes(), []byte("blob_integrity_failed")) {
		t.Fatalf("truncated: status=%d body=%q", rec.Code, rec.Body.Bytes())
	}
}

// A blob stored before chunk records (NULL) is still verified in full on
// every open until a full verification succeeds; that pass then stores the
// record, and later ranges verify only their chunks.
func TestLegacyAttachmentIsVerifiedInFullThenGetsARecord(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	payload := blobTestPayload(3*chunk + 10)
	id, path := uploadTestAttachment(t, handler, token, dbPath, payload)
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var record []byte
	if err := db.QueryRow(`SELECT chunk_digests FROM attachment_envelopes WHERE id = ?`, id).Scan(&record); err != nil {
		t.Fatal(err)
	}
	if want := 33 + 4*32; len(record) != want {
		t.Fatalf("upload record is %d bytes, want %d", len(record), want)
	}
	if _, err := db.Exec(`UPDATE attachment_envelopes SET chunk_digests = NULL WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	url := "/api/v1/attachments/" + id

	flipBlobByte(t, path, 2*chunk+1)
	if rec := getBlob(handler, url, token, "bytes=0-99"); rec.Code != http.StatusInternalServerError {
		t.Fatalf("legacy blob with a bad chunk elsewhere: status=%d", rec.Code)
	}
	assertNullRecord(t, db, id)
	flipBlobByte(t, path, 2*chunk+1)

	if rec := getBlob(handler, url, token, "bytes=0-99"); rec.Code != http.StatusPartialContent || !bytes.Equal(rec.Body.Bytes(), payload[:100]) {
		t.Fatalf("legacy range: status=%d", rec.Code)
	}
	var rebuilt []byte
	if err := db.QueryRow(`SELECT chunk_digests FROM attachment_envelopes WHERE id = ?`, id).Scan(&rebuilt); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(rebuilt, record) {
		t.Fatal("stored record differs from the one written at upload")
	}
	flipBlobByte(t, path, 2*chunk+1)
	if rec := getBlob(handler, url, token, "bytes=0-99"); rec.Code != http.StatusPartialContent || !bytes.Equal(rec.Body.Bytes(), payload[:100]) {
		t.Fatalf("range after record stored: status=%d", rec.Code)
	}
}

// Recovery: an aborted transfer records only the verified bytes it handed
// off, and resuming at the bad chunk gets a clean blob_integrity_failed.
func TestRecoveryStopsAtABadChunk(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	payload := blobTestPayload(3*chunk + 10)
	recoveryToken := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/backups", token, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
		"X-Recovery-Token":              recoveryToken,
	})
	if status != http.StatusCreated {
		t.Fatalf("backup status=%d body=%s", status, response)
	}
	var backup struct {
		StorageKey string `json:"storage_key"`
	}
	if err := json.Unmarshal(response, &backup); err != nil {
		t.Fatal(err)
	}
	flipBlobByte(t, filepath.Join(filepath.Dir(dbPath), "blobs", backup.StorageKey), 2*chunk+3)

	server := httptest.NewServer(handler)
	defer server.Close()
	request, err := http.NewRequest(http.MethodGet, server.URL+"/api/v1/recovery", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Recovery-Token", recoveryToken)
	resp, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, readErr := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || readErr == nil || len(body) > 2*chunk || !bytes.Equal(body, payload[:len(body)]) {
		t.Fatalf("aborted recovery: status=%d read=%d err=%v", resp.StatusCode, len(body), readErr)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var next int64
	var lease sql.NullString
	if err := db.QueryRow(`SELECT recovery_next_offset, recovery_lease_id FROM backup_blobs WHERE storage_key = ?`, backup.StorageKey).Scan(&next, &lease); err != nil {
		t.Fatal(err)
	}
	if next != 2*chunk || lease.Valid {
		t.Fatalf("recorded progress = %d (lease held %v), want %d", next, lease.Valid, 2*chunk)
	}
	status, response = doRaw(t, handler, http.MethodGet, "/api/v1/recovery", "", nil, map[string]string{
		"X-Recovery-Token": recoveryToken, "Range": fmt.Sprintf("bytes=%d-", 2*chunk),
	})
	if status != http.StatusInternalServerError || !bytes.Contains(response, []byte("blob_integrity_failed")) {
		t.Fatalf("resume at bad chunk: status=%d body=%q", status, response)
	}
	status, response = doRaw(t, handler, http.MethodGet, "/api/v1/recovery", "", nil, map[string]string{
		"X-Recovery-Token": recoveryToken, "Range": fmt.Sprintf("bytes=%d-%d", chunk, 2*chunk-1),
	})
	if status != http.StatusPartialContent || !bytes.Equal(response, payload[chunk:2*chunk]) {
		t.Fatalf("resume of intact range: status=%d len=%d", status, len(response))
	}
}

func blobTestPayload(size int) []byte {
	payload := make([]byte, size)
	random := rand.New(rand.NewPCG(uint64(size), 6))
	for i := range payload {
		payload[i] = byte(random.Uint32())
	}
	return payload
}

func uploadTestAttachment(t *testing.T, handler http.Handler, token, dbPath string, payload []byte) (string, string) {
	t.Helper()
	conversationID := createConversation(t, handler, token)
	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/attachments?conversation_id="+conversationID, token, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Crypto-Metadata":             `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`,
	})
	if status != http.StatusCreated {
		t.Fatalf("upload status=%d body=%s", status, response)
	}
	if bytes.Contains(response, []byte("chunk_digests")) {
		t.Fatalf("upload response exposes the chunk record: %s", response)
	}
	var attachment struct {
		ID         string `json:"id"`
		StorageKey string `json:"storage_key"`
	}
	if err := json.Unmarshal(response, &attachment); err != nil {
		t.Fatal(err)
	}
	return attachment.ID, filepath.Join(filepath.Dir(dbPath), "blobs", attachment.StorageKey)
}

func getBlob(handler http.Handler, url, token, rangeHeader string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	if rangeHeader != "" {
		req.Header.Set("Range", rangeHeader)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

// fetchBlob downloads over a real connection, where an aborted handler is
// visible as a broken transfer: no response at all (status 0) when it
// aborts before the headers leave the server's buffer, else a short body.
func fetchBlob(t *testing.T, url, token, rangeHeader string) (int, []byte, error) {
	t.Helper()
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if rangeHeader != "" {
		req.Header.Set("Range", rangeHeader)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	return resp.StatusCode, body, err
}

func flipBlobByte(t *testing.T, path string, offset int64) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	b := make([]byte, 1)
	if _, err := file.ReadAt(b, offset); err != nil {
		t.Fatal(err)
	}
	b[0] ^= 0xFF
	if _, err := file.WriteAt(b, offset); err != nil {
		t.Fatal(err)
	}
}

func assertNullRecord(t *testing.T, db *sql.DB, id string) {
	t.Helper()
	var record []byte
	if err := db.QueryRow(`SELECT chunk_digests FROM attachment_envelopes WHERE id = ?`, id).Scan(&record); err != nil {
		t.Fatal(err)
	}
	if record != nil {
		t.Fatal("record stored after a failed verification")
	}
}
