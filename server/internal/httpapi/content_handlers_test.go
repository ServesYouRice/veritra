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
	api := &API{Blobs: &downloadTestStore{reader: reader}}
	w := &interruptingResponseWriter{header: make(http.Header), remaining: 1024}
	api.serveEncryptedBlob(w, httptest.NewRequest(http.MethodGet, "/download", nil), uploads.BlobRef{StorageKey: "blob_test", SHA256: "digest", Size: int64(len(payload))})
	if reader.bytesRead >= int64(len(payload)) {
		t.Fatalf("read entire blob after client interruption: %d bytes", reader.bytesRead)
	}
	if !w.interrupted {
		t.Fatal("response writer did not interrupt the download")
	}
}

type downloadTestStore struct {
	reader *countingReadSeekCloser
}

func (s *downloadTestStore) Check(context.Context) error { return nil }
func (s *downloadTestStore) PutEncryptedBlob(context.Context, io.Reader) (uploads.BlobRef, error) {
	return uploads.BlobRef{}, errors.New("not implemented")
}
func (s *downloadTestStore) Open(context.Context, uploads.BlobRef) (uploads.Blob, error) {
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

func (r *countingReadSeekCloser) Close() error                   { return nil }
func (r *countingReadSeekCloser) VerifyCurrent() error           { return nil }
func (r *countingReadSeekCloser) Err() error                     { return nil }
func (r *countingReadSeekCloser) RecomputedChunkDigests() []byte { return nil }

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
