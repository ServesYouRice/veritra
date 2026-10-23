package uploads

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

// T49B: blob verification, upload admission, disk use and directory
// reconciliation. All payloads are synthetic random ciphertext.

const (
	kib = 1 << 10
	mib = 1 << 20
	// Mirrors the attachment and backup body caps in httpapi.
	attachmentCap = 50 * mib
	backupCap     = 100 * mib
)

var benchChunk = func() []byte {
	b := make([]byte, mib)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}()

// cipherReader streams size bytes of synthetic ciphertext without
// allocating the whole body.
type cipherReader struct {
	remaining int64
	off       int
}

func newCipherReader(size int64) *cipherReader { return &cipherReader{remaining: size} }

func (r *cipherReader) Read(p []byte) (int, error) {
	if r.remaining <= 0 {
		return 0, io.EOF
	}
	if int64(len(p)) > r.remaining {
		p = p[:r.remaining]
	}
	n := copy(p, benchChunk[r.off:])
	r.off = (r.off + n) % len(benchChunk)
	r.remaining -= int64(n)
	return n, nil
}

func newBenchLocalStore(b *testing.B) *LocalStore {
	b.Helper()
	store, err := NewLocalStore(filepath.Join(b.TempDir(), "blobs"))
	if err != nil {
		b.Fatal(err)
	}
	return store
}

func putBenchBlob(b *testing.B, store *LocalStore, size int64) BlobRef {
	b.Helper()
	ref, err := store.PutEncryptedBlob(context.Background(), newCipherReader(size))
	if err != nil || ref.Size != size {
		b.Fatalf("put: %d %v", ref.Size, err)
	}
	return ref
}

func sizeName(size int64) string {
	if size >= mib {
		return fmt.Sprintf("%dMiB", size/mib)
	}
	return fmt.Sprintf("%dKiB", size/kib)
}

func BenchmarkPutEncryptedBlob(b *testing.B) {
	for _, size := range []int64{64 * kib, mib, 16 * mib, attachmentCap} {
		b.Run(sizeName(size), func(b *testing.B) {
			store := newBenchLocalStore(b)
			b.SetBytes(size)
			for b.Loop() {
				ref := putBenchBlob(b, store, size)
				b.StopTimer()
				_ = store.Delete(context.Background(), ref.StorageKey)
				b.StartTimer()
			}
		})
	}
}

// Concurrent uploads each fsync their file and the shared blob directory.
func BenchmarkPutEncryptedBlobParallel(b *testing.B) {
	for _, size := range []int64{64 * kib, mib} {
		b.Run(sizeName(size), func(b *testing.B) {
			store := newBenchLocalStore(b)
			b.SetBytes(size)
			b.SetParallelism(4)
			b.RunParallel(func(pb *testing.PB) {
				for pb.Next() {
					ref, err := store.PutEncryptedBlob(context.Background(), newCipherReader(size))
					if err != nil {
						b.Error(err)
						return
					}
					_ = store.Delete(context.Background(), ref.StorageKey)
				}
			})
		})
	}
}

// An oversized attachment is rejected only after the cap is streamed to a
// temporary file; quota is checked after the blob is durable.
func BenchmarkPutEncryptedBlobOversized(b *testing.B) {
	store := newBenchLocalStore(b)
	const body = attachmentCap + 10*mib
	var written int64
	for b.Loop() {
		recorder := httptest.NewRecorder()
		counting := &countingReader{reader: newCipherReader(body)}
		_, err := store.PutEncryptedBlob(context.Background(), http.MaxBytesReader(recorder, io.NopCloser(counting), attachmentCap))
		var maxErr *http.MaxBytesError
		if !errors.As(err, &maxErr) {
			b.Fatalf("expected MaxBytesError, got %v", err)
		}
		written = counting.n
	}
	b.ReportMetric(float64(written), "bytes_read_before_reject")
	entries, _ := os.ReadDir(store.root)
	b.ReportMetric(float64(len(entries)), "leftover_files")
}

type countingReader struct {
	reader io.Reader
	n      int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.reader.Read(p)
	c.n += int64(n)
	return n, err
}

// Open checks the size, then each read verifies only the 64 KiB chunks it
// touches, so a range read costs about one chunk hash. RangeLegacy64KiB is a
// blob stored before chunk records (no record): Open hashes it all first,
// as every Open did before miss 6 was fixed.
func BenchmarkOpenVerify(b *testing.B) {
	ctx := context.Background()
	for _, size := range []int64{64 * kib, mib, 16 * mib, attachmentCap, backupCap} {
		store := newBenchLocalStore(b)
		ref := putBenchBlob(b, store, size)
		legacy := ref
		legacy.ChunkDigests = nil
		rangeRead := func(b *testing.B, ref BlobRef) {
			for b.Loop() {
				file, err := store.Open(ctx, ref)
				if err != nil {
					b.Fatal(err)
				}
				start := size - 64*kib
				if start < 0 {
					start = 0
				}
				if _, err := file.Seek(start, io.SeekStart); err != nil {
					b.Fatal(err)
				}
				if _, err := io.CopyN(io.Discard, file, 64*kib); err != nil && !errors.Is(err, io.EOF) {
					b.Fatal(err)
				}
				file.Close()
			}
		}
		b.Run("Full/"+sizeName(size), func(b *testing.B) {
			b.SetBytes(size)
			for b.Loop() {
				file, err := store.Open(ctx, ref)
				if err != nil {
					b.Fatal(err)
				}
				if _, err := io.Copy(io.Discard, file); err != nil {
					b.Fatal(err)
				}
				file.Close()
			}
		})
		b.Run("Range64KiB/"+sizeName(size), func(b *testing.B) { rangeRead(b, ref) })
		b.Run("RangeLegacy64KiB/"+sizeName(size), func(b *testing.B) { rangeRead(b, legacy) })
		b.Run("SHA256Only/"+sizeName(size), func(b *testing.B) {
			b.SetBytes(size)
			for b.Loop() {
				file, err := os.Open(filepath.Join(store.root, ref.StorageKey))
				if err != nil {
					b.Fatal(err)
				}
				hash := sha256.New()
				if _, err := io.Copy(hash, file); err != nil {
					b.Fatal(err)
				}
				file.Close()
				_ = hex.EncodeToString(hash.Sum(nil))
			}
		})
	}
}

// Disk use: allocated bytes per blob for small ciphertexts in the flat
// layout (filesystem block rounding), reported per blob.
func BenchmarkDiskUse(b *testing.B) {
	for _, size := range []int64{1, kib, 4*kib + 1, 64 * kib} {
		b.Run(fmt.Sprintf("%dB", size), func(b *testing.B) {
			store := newBenchLocalStore(b)
			keys := make([]string, 0, 256)
			for b.Loop() {
				ref := putBenchBlob(b, store, size)
				if len(keys) < cap(keys) {
					keys = append(keys, ref.StorageKey)
				}
			}
			var allocated int64
			for _, key := range keys {
				info, err := os.Stat(filepath.Join(store.root, key))
				if err != nil {
					b.Fatal(err)
				}
				if st, ok := info.Sys().(*syscall.Stat_t); ok {
					allocated += st.Blocks * 512
				}
			}
			if len(keys) > 0 {
				b.ReportMetric(float64(allocated)/float64(len(keys)), "disk_bytes/blob")
				b.ReportMetric(float64(allocated)/float64(int64(len(keys))*size), "disk/logical")
			}
		})
	}
}

// Directory reconciliation: the startup/periodic temporary-file sweep scans
// the single flat blob directory, so its cost grows with total blobs.
func BenchmarkCleanupTemporaryFiles(b *testing.B) {
	ctx := context.Background()
	for _, count := range []int{1_000, 10_000, 100_000} {
		store := newBenchLocalStore(b)
		payload := bytes.Repeat([]byte{0x5A}, 512)
		for i := 0; i < count; i++ {
			id, err := domain.NewID("blob")
			if err != nil {
				b.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(store.root, id), payload, 0o600); err != nil {
				b.Fatal(err)
			}
		}
		// A few stale partial uploads; recreated after each sweep.
		stale := time.Now().Add(-48 * time.Hour)
		makeStale := func() {
			for i := 0; i < 10; i++ {
				path := filepath.Join(store.root, fmt.Sprintf("blob_stale%d.tmp", i))
				if err := os.WriteFile(path, payload, 0o600); err != nil {
					b.Fatal(err)
				}
				if err := os.Chtimes(path, stale, stale); err != nil {
					b.Fatal(err)
				}
			}
		}
		b.Run(fmt.Sprintf("blobs%d", count), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				b.StopTimer()
				makeStale()
				b.StartTimer()
				removed, err := store.CleanupTemporaryFiles(ctx, time.Now().Add(-24*time.Hour))
				if err != nil || removed != 10 {
					b.Fatalf("cleanup: %d %v", removed, err)
				}
			}
		})
	}
}
