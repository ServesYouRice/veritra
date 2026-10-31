package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// Attachment and backup downloads serve at most one byte range. A header
// with many small ranges would otherwise make the server seek and re-verify
// chunks once per range (VAL-228); a single range keeps working.
func TestBlobDownloadRejectsMultiRange(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, ownerToken)
	payload := []byte("encrypted attachment payload")

	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/attachments?conversation_id="+conversationID, ownerToken, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Crypto-Metadata":             `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`,
	})
	if status != http.StatusCreated {
		t.Fatalf("attachment upload status=%d body=%s", status, response)
	}
	var attachment struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &attachment); err != nil || attachment.ID == "" {
		t.Fatalf("attachment response %s: %v", response, err)
	}

	backupPayload := []byte("encrypted backup blob payload")
	status, response = doRaw(t, handler, http.MethodPost, "/api/v1/backups", ownerToken, backupPayload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
		"X-Recovery-Token":              base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, 32)),
	})
	if status != http.StatusCreated {
		t.Fatalf("backup upload status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/backups", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("list backups status=%d body=%s", status, response)
	}
	var listed struct {
		Backups []struct {
			ID string `json:"id"`
		} `json:"backups"`
	}
	if err := json.Unmarshal(response, &listed); err != nil || len(listed.Backups) != 1 || listed.Backups[0].ID == "" {
		t.Fatalf("backup list %s: %v", response, err)
	}
	backup := listed.Backups[0]

	routes := []struct {
		name, path string
		payload    []byte
	}{
		{"attachment", "/api/v1/attachments/" + attachment.ID, payload},
		{"backup", "/api/v1/backups/" + backup.ID, backupPayload},
	}
	get := func(path, rangeHeader string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+ownerToken)
		if rangeHeader != "" {
			req.Header.Set("Range", rangeHeader)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	for _, route := range routes {
		t.Run(route.name, func(t *testing.T) {
			many := "bytes=" + strings.TrimSuffix(strings.Repeat("0-0,2-2,", 500), ",")
			for _, header := range []string{"bytes=0-0,2-2", "bytes=0-0, 2-2", many} {
				rec := get(route.path, header)
				if rec.Code != http.StatusRequestedRangeNotSatisfiable {
					t.Fatalf("Range %.30q status=%d, want 416", header, rec.Code)
				}
				if got, want := rec.Header().Get("Content-Range"), "bytes */"+strconv.Itoa(len(route.payload)); got != want {
					t.Fatalf("Content-Range = %q, want %q", got, want)
				}
				if strings.Contains(rec.Header().Get("Content-Type"), "multipart") || bytes.Contains(rec.Body.Bytes(), route.payload[:4]) {
					t.Fatalf("multi-range request served content: %q", rec.Body.String())
				}
			}
			rec := get(route.path, "bytes=10-19")
			if rec.Code != http.StatusPartialContent || !bytes.Equal(rec.Body.Bytes(), route.payload[10:20]) {
				t.Fatalf("single range status=%d body=%q", rec.Code, rec.Body.Bytes())
			}
			if got, want := rec.Header().Get("Content-Range"), "bytes 10-19/"+strconv.Itoa(len(route.payload)); got != want {
				t.Fatalf("single range Content-Range = %q, want %q", got, want)
			}
			if rec := get(route.path, ""); rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), route.payload) {
				t.Fatalf("full download status=%d", rec.Code)
			}
		})
	}
}
