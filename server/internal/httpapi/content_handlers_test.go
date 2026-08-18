package httpapi

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"private-messenger/server/internal/uploads"
)

func TestServeEncryptedBlobStopsAfterInterruptedDownload(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), 1<<20)
	reader := &countingReadSeekCloser{Reader: bytes.NewReader(payload)}
	blobs := &downloadTestStore{reader: reader}
	w := &interruptingResponseWriter{header: make(http.Header), remaining: 1024}
	serveEncryptedBlob(w, httptest.NewRequest(http.MethodGet, "/download", nil), blobs, "blob_test", "digest", int64(len(payload)))
	if reader.bytesRead >= int64(len(payload)) {
		t.Fatalf("read entire blob after client interruption: %d bytes", reader.bytesRead)
	}
	if !w.interrupted {
		t.Fatal("response writer did not interrupt the download")
	}
}

func TestRecoveryRangeRequiresSingleContiguousRange(t *testing.T) {
	tests := []struct {
		name   string
		header string
		start  int64
		end    int64
		valid  bool
	}{
		{name: "full", start: 0, end: 99, valid: true},
		{name: "bounded", header: "bytes=10-19", start: 10, end: 19, valid: true},
		{name: "open ended", header: "bytes=10-", start: 10, end: 99, valid: true},
		{name: "suffix rejected", header: "bytes=-10", valid: false},
		{name: "multiple rejected", header: "bytes=0-9,10-19", valid: false},
		{name: "invalid end", header: "bytes=20-10", valid: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/api/v1/recovery", nil)
			if test.header != "" {
				request.Header.Set("Range", test.header)
			}
			start, end, err := recoveryRange(request, 100)
			if test.valid {
				if err != nil || start != test.start || end != test.end {
					t.Fatalf("range=(%d,%d) err=%v", start, end, err)
				}
			} else if err == nil {
				t.Fatalf("accepted invalid range (%d,%d)", start, end)
			}
		})
	}
}

type downloadTestStore struct {
	reader uploads.ReadSeekCloser
}

func (s *downloadTestStore) Check(context.Context) error { return nil }
func (s *downloadTestStore) PutEncryptedBlob(context.Context, io.Reader) (string, string, int64, error) {
	return "", "", 0, errors.New("not implemented")
}
func (s *downloadTestStore) Open(context.Context, string, string, int64) (uploads.ReadSeekCloser, error) {
	return s.reader, nil
}
func (s *downloadTestStore) Delete(context.Context, string) error { return nil }

type countingReadSeekCloser struct {
	*bytes.Reader
	bytesRead int64
}

func (r *countingReadSeekCloser) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	r.bytesRead += int64(n)
	return n, err
}

func (r *countingReadSeekCloser) Close() error { return nil }

type interruptingResponseWriter struct {
	header      http.Header
	remaining   int
	interrupted bool
}

func (w *interruptingResponseWriter) Header() http.Header { return w.header }
func (w *interruptingResponseWriter) WriteHeader(int)     {}
func (w *interruptingResponseWriter) Write(p []byte) (int, error) {
	if len(p) <= w.remaining {
		w.remaining -= len(p)
		return len(p), nil
	}
	written := w.remaining
	w.remaining = 0
	w.interrupted = true
	return written, errors.New("client disconnected")
}
