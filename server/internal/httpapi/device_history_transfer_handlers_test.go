package httpapi_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"private-messenger/server/internal/storage"
)

func historyMultipart(t *testing.T, input interface{}, data []byte, extra bool) ([]byte, string) {
	t.Helper()
	var b bytes.Buffer
	w := multipart.NewWriter(&b)
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", `form-data; name="metadata"`)
	header.Set("Content-Type", "application/json")
	p, err := w.CreatePart(header)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = p.Write(raw); err != nil {
		t.Fatal(err)
	}
	header = make(textproto.MIMEHeader)
	header.Set("Content-Disposition", `form-data; name="ciphertext"`)
	header.Set("Content-Type", "application/octet-stream")
	p, err = w.CreatePart(header)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = p.Write(data); err != nil {
		t.Fatal(err)
	}
	if extra {
		if _, err = w.CreateFormField("extra"); err != nil {
			t.Fatal(err)
		}
	}
	if err = w.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes(), w.FormDataContentType()
}

func historyHTTPInput(f *v3APIFixture, data []byte) storage.HistoryTransferInput {
	d := sha256.Sum256(data)
	return storage.HistoryTransferInput{ProtocolVersion: storage.DeviceLinkV3Protocol, TransferID: strings.Repeat("b", 64), ClaimRequestHash: f.link.ClaimRequestHash, TranscriptHash: f.claim.TranscriptHash, CiphertextSHA256: hex.EncodeToString(d[:]), SizeBytes: int64(len(data)), Handoff: []byte("opaque handoff")}
}

var historyContractAddress atomic.Int32

func historyRequest(t *testing.T, f *v3APIFixture, method, path, token string, body []byte, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	// Keep this transport contract independent of the separately tested
	// credential-address limiter, including setup requests from the fixture.
	r.RemoteAddr = "198.51.100." + strconv.Itoa(int(historyContractAddress.Add(1)%250)+1) + ":1234"
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	f.handler.ServeHTTP(w, r)
	return w
}

func TestHistoryTransferHTTPUploadRangeRetryAndDurableAck(t *testing.T) {
	f := newV3APIFixture(t)
	f.approve(t)
	data := bytes.Repeat([]byte("encrypted-history"), 10000)
	input := historyHTTPInput(f, data)
	body, ctype := historyMultipart(t, input, data, false)
	base := v3Base + "/" + f.link.ID + "/history"
	w := historyRequest(t, f, http.MethodPost, base, f.ownerToken, body, map[string]string{"Content-Type": ctype})
	if w.Code != http.StatusCreated {
		t.Fatalf("upload %d %s", w.Code, w.Body.String())
	}
	first := bytes.Clone(w.Body.Bytes())
	w = historyRequest(t, f, http.MethodPost, base, f.ownerToken, body, map[string]string{"Content-Type": ctype})
	if w.Code != http.StatusOK || !bytes.Equal(first, w.Body.Bytes()) {
		t.Fatalf("upload retry %d %s", w.Code, w.Body.String())
	}
	headers := map[string]string{"X-Veritra-Claim-Token": f.claimToken}
	w = historyRequest(t, f, http.MethodGet, base, "", nil, headers)
	if w.Code != http.StatusOK || !bytes.Contains(w.Body.Bytes(), []byte(`"handoff":`)) || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("metadata %d %s", w.Code, w.Body.String())
	}
	w = historyRequest(t, f, http.MethodGet, base, f.ownerToken, nil, nil)
	if w.Code != http.StatusOK || bytes.Contains(w.Body.Bytes(), []byte(`"handoff":`)) {
		t.Fatalf("source metadata %d %s", w.Code, w.Body.String())
	}
	w = historyRequest(t, f, http.MethodGet, base+"/content", f.ownerToken, nil, nil)
	if w.Code != http.StatusForbidden {
		t.Fatalf("source content %d", w.Code)
	}
	for i := 0; i < 2; i++ {
		headers["Range"] = "bytes=100-999"
		headers["If-Range"] = `"sha256-` + input.CiphertextSHA256 + `"`
		w = historyRequest(t, f, http.MethodGet, base+"/content", "", nil, headers)
		if w.Code != http.StatusPartialContent || !bytes.Equal(w.Body.Bytes(), data[100:1000]) || w.Header().Get("ETag") != headers["If-Range"] {
			t.Fatalf("range retry %d %d", w.Code, w.Body.Len())
		}
	}
	headers["Range"] = "bytes=999999-"
	delete(headers, "If-Range")
	w = historyRequest(t, f, http.MethodGet, base+"/content", "", nil, headers)
	if w.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("bad range %d", w.Code)
	}
	delete(headers, "Range")
	headers["Authorization"] = "Bearer invalid"
	w = historyRequest(t, f, http.MethodGet, base, "", nil, headers)
	if w.Code == http.StatusOK {
		t.Fatal("invalid session fell back to claim")
	}
	delete(headers, "Authorization")
	if status, response := f.complete(t); status != http.StatusOK {
		t.Fatalf("complete %d %s", status, response)
	}
	w = historyRequest(t, f, http.MethodGet, base+"/content", f.sessionToken, nil, nil)
	if w.Code != http.StatusOK || !bytes.Equal(w.Body.Bytes(), data) {
		t.Fatalf("recipient session %d", w.Code)
	}
	ack, _ := json.Marshal(map[string]interface{}{"protocol_version": storage.DeviceLinkV3Protocol, "transfer_id": input.TransferID, "ciphertext_sha256": input.CiphertextSHA256})
	for i := 0; i < 2; i++ {
		w = historyRequest(t, f, http.MethodPost, base+"/ack", "", ack, headers)
		if w.Code != http.StatusOK || !bytes.Contains(w.Body.Bytes(), []byte(`"state":"acknowledged"`)) {
			t.Fatalf("ack %d %s", w.Code, w.Body.String())
		}
	}
	w = historyRequest(t, f, http.MethodGet, base+"/content", "", nil, headers)
	if w.Code == http.StatusOK {
		t.Fatal("ACK did not retire download")
	}
	var handoff, key interface{}
	if err := f.db.QueryRow(`SELECT handoff,storage_key FROM device_history_transfers WHERE link_id=?`, f.link.ID).Scan(&handoff, &key); err != nil || handoff != nil || key != nil {
		t.Fatalf("secret refs retained %v %v %v", handoff, key, err)
	}
	for _, secret := range []string{f.claimToken, f.deviceSecret, f.sessionToken, "storage_key"} {
		if bytes.Contains(first, []byte(secret)) {
			t.Fatal("private data in receipt")
		}
	}
}

func TestHistoryTransferHTTPRejectsMalformedOrReplacedUpload(t *testing.T) {
	for _, mode := range []string{"extra part", "wrong digest", "wrong size", "large handoff", "large ciphertext declaration", "wrong transcript", "unknown metadata", "wrong uploader"} {
		t.Run(mode, func(t *testing.T) {
			f := newV3APIFixture(t)
			f.approve(t)
			data := []byte("ciphertext")
			input := historyHTTPInput(f, data)
			var payload interface{} = input
			token := f.ownerToken
			switch mode {
			case "wrong digest":
				input.CiphertextSHA256 = strings.Repeat("0", 64)
			case "wrong size":
				input.SizeBytes++
			case "large handoff":
				input.Handoff = make([]byte, 8193)
			case "large ciphertext declaration":
				input.SizeBytes = storage.MaxHistoryCiphertext + 1
			case "wrong transcript":
				input.TranscriptHash = make([]byte, 32)
			case "wrong uploader":
				if status, _ := f.complete(t); status != http.StatusOK {
					t.Fatal(status)
				}
				token = f.sessionToken
			}
			payload = input
			if mode == "unknown metadata" {
				raw, _ := json.Marshal(input)
				var m map[string]interface{}
				_ = json.Unmarshal(raw, &m)
				m["file_key"] = "forbidden"
				payload = m
			}
			body, ctype := historyMultipart(t, payload, data, mode == "extra part")
			w := historyRequest(t, f, http.MethodPost, v3Base+"/"+f.link.ID+"/history", token, body, map[string]string{"Content-Type": ctype})
			if w.Code < 400 {
				t.Fatalf("invalid upload accepted %d %s", w.Code, w.Body.String())
			}
			var active int
			if err := f.db.QueryRow(`SELECT COUNT(*) FROM device_history_transfers WHERE state='active'`).Scan(&active); err != nil || active != 0 {
				t.Fatalf("invalid upload committed %d %v", active, err)
			}
		})
	}
}
