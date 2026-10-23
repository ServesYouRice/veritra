package uploads

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestLocalStorePutSyncsAndOpenValidates(t *testing.T) {
	store := newTestLocalStore(t)
	payload := []byte("encrypted bytes")
	ref, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	file, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	got, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("payload = %q, want %q", got, payload)
	}
}

func TestLocalStorePutFailureLeavesNoBlob(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*LocalStore)
	}{
		{"file sync", func(store *LocalStore) { store.syncFile = func(*os.File) error { return errors.New("sync failed") } }},
		{"rename", func(store *LocalStore) {
			store.rename = func(string, string) error { return errors.New("rename failed") }
		}},
		{"directory sync", func(store *LocalStore) {
			store.syncDirectory = func(string) error { return errors.New("directory sync failed") }
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store := newTestLocalStore(t)
			test.mutate(store)
			if _, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader([]byte("ciphertext"))); err == nil {
				t.Fatal("PutEncryptedBlob succeeded")
			}
			assertEmptyDirectory(t, store.root)
		})
	}
}

func TestLocalStorePutInterruptedRemovesTemporaryFile(t *testing.T) {
	store := newTestLocalStore(t)
	ctx, cancel := context.WithCancel(context.Background())
	reader := &cancelingReader{cancel: cancel}
	if _, err := store.PutEncryptedBlob(ctx, reader); !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context canceled", err)
	}
	assertEmptyDirectory(t, store.root)
}

func TestLocalStoreOpenRejectsTruncatedOrCorruptBlob(t *testing.T) {
	store := newTestLocalStore(t)
	payload := []byte("encrypted bytes")
	ref, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	legacy := ref
	legacy.ChunkDigests = nil
	path := filepath.Join(store.root, ref.StorageKey)
	if err := os.Truncate(path, ref.Size-1); err != nil {
		t.Fatal(err)
	}
	for _, r := range []BlobRef{ref, legacy} {
		if _, err := store.Open(context.Background(), r); !errors.Is(err, ErrBlobIntegrity) {
			t.Fatalf("truncated error = %v, want integrity error", err)
		}
	}
	if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, int(ref.Size)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Open(context.Background(), legacy); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("corrupt legacy error = %v, want integrity error", err)
	}
	blob, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := blob.Read(make([]byte, 64)); n != 0 || !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("corrupt read = %d, %v; want 0, integrity error", n, err)
	}
	blob.Close()
	badDigest := sha256.Sum256([]byte("different"))
	wrong := ref
	wrong.SHA256 = hex.EncodeToString(badDigest[:])
	if _, err := store.Open(context.Background(), wrong); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("digest error = %v, want integrity error", err)
	}
}

func TestLocalStoreRejectsUnsafeStorageKey(t *testing.T) {
	store := newTestLocalStore(t)
	if _, err := store.Open(context.Background(), BlobRef{StorageKey: "../blob_example"}); !errors.Is(err, ErrInvalidStorageKey) {
		t.Fatalf("error = %v, want invalid storage key", err)
	}
}

// T49B miss 6: the record written with a blob holds the whole digest and
// one digest per 64 KiB chunk, and a blob opened with it reads back intact.
func TestLocalStorePutRecordsChunkDigests(t *testing.T) {
	for _, size := range []int{0, 1, ChunkSize - 1, ChunkSize, ChunkSize + 1, 3*ChunkSize + 17} {
		store := newTestLocalStore(t)
		payload := testPayload(size)
		ref, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader(payload))
		if err != nil {
			t.Fatal(err)
		}
		full := sha256.Sum256(payload)
		if ref.Size != int64(size) || ref.SHA256 != hex.EncodeToString(full[:]) {
			t.Fatalf("size %d: ref = %d %s", size, ref.Size, ref.SHA256)
		}
		want := append([]byte{chunkRecordVersion}, full[:]...)
		for start := 0; start < size; start += ChunkSize {
			sum := sha256.Sum256(payload[start:min(start+ChunkSize, size)])
			want = append(want, sum[:]...)
		}
		if !bytes.Equal(ref.ChunkDigests, want) {
			t.Fatalf("size %d: record of %d bytes, want %d", size, len(ref.ChunkDigests), len(want))
		}
		blob, err := store.Open(context.Background(), ref)
		if err != nil {
			t.Fatal(err)
		}
		if blob.RecomputedChunkDigests() != nil {
			t.Fatalf("size %d: blob with a record was verified in full", size)
		}
		got, err := io.ReadAll(blob)
		blob.Close()
		if err != nil || !bytes.Equal(got, payload) {
			t.Fatalf("size %d: read %d bytes, err %v", size, len(got), err)
		}
	}
}

func TestLocalStoreRangeVerifiesOnlyTouchedChunks(t *testing.T) {
	store := newTestLocalStore(t)
	payload := testPayload(4*ChunkSize + 100)
	ref := putTestBlob(t, store, payload)
	corruptByte(t, filepath.Join(store.root, ref.StorageKey), 2*ChunkSize+7)

	// Chunks 0, 1, 3 and the tail are intact and served.
	blob, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	defer blob.Close()
	assertRange(t, blob, payload, 10, 2*ChunkSize-10)
	assertRange(t, blob, payload, 3*ChunkSize+5, ChunkSize+95)

	// A read that runs into chunk 2 stops at the boundary: every byte it
	// returned is intact, and the bad chunk is reported.
	if _, err := blob.Seek(ChunkSize+100, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 2*ChunkSize)
	n, err := io.ReadFull(blob, got)
	if !errors.Is(err, ErrBlobIntegrity) || n != ChunkSize-100 || !bytes.Equal(got[:n], payload[ChunkSize+100:2*ChunkSize]) {
		t.Fatalf("read across bad chunk = %d, %v", n, err)
	}
	// The failure is sticky, even for intact chunks.
	if _, err := blob.Seek(0, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	if n, err := blob.Read(got); n != 0 || !errors.Is(err, ErrBlobIntegrity) || !errors.Is(blob.Err(), ErrBlobIntegrity) {
		t.Fatalf("read after failure = %d, %v (Err %v)", n, err, blob.Err())
	}

	// A range that starts inside the bad chunk returns nothing.
	second, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if _, err := second.Seek(2*ChunkSize+ChunkSize/2, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	if err := second.VerifyCurrent(); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("VerifyCurrent = %v, want integrity error", err)
	}
	if n, err := second.Read(got); n != 0 || !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("read in bad chunk = %d, %v", n, err)
	}
}

// Bytes are served from the buffer that was hashed, so a change to the file
// after a chunk was verified cannot reach the reader; a chunk not yet
// verified is checked against the record when it is read.
func TestLocalStoreServesOnlyVerifiedBytes(t *testing.T) {
	store := newTestLocalStore(t)
	payload := testPayload(2 * ChunkSize)
	ref := putTestBlob(t, store, payload)
	path := filepath.Join(store.root, ref.StorageKey)
	blob, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	defer blob.Close()
	if err := blob.VerifyCurrent(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, len(payload)), 0o600); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, ChunkSize)
	if _, err := io.ReadFull(blob, got); err != nil || !bytes.Equal(got, payload[:ChunkSize]) {
		t.Fatalf("verified chunk read = %v", err)
	}
	if n, err := blob.Read(got); n != 0 || !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("rewritten chunk read = %d, %v", n, err)
	}
}

func TestLocalStoreLegacyBlobIsVerifiedInFullAndRecordRebuilt(t *testing.T) {
	store := newTestLocalStore(t)
	payload := testPayload(3*ChunkSize + 1)
	ref := putTestBlob(t, store, payload)
	legacy := ref
	legacy.ChunkDigests = nil

	blob, err := store.Open(context.Background(), legacy)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(blob.RecomputedChunkDigests(), ref.ChunkDigests) {
		t.Fatal("rebuilt record differs from the record written with the blob")
	}
	got, err := io.ReadAll(blob)
	blob.Close()
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("legacy read %d bytes, err %v", len(got), err)
	}

	// Without a record a bad chunk anywhere fails Open, as before.
	corruptByte(t, filepath.Join(store.root, ref.StorageKey), 3*ChunkSize)
	if _, err := store.Open(context.Background(), legacy); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("corrupt legacy open = %v, want integrity error", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.Open(ctx, legacy); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled legacy open = %v", err)
	}
}

func TestLocalStoreMalformedRecordFallsBackToFullVerification(t *testing.T) {
	store := newTestLocalStore(t)
	payload := testPayload(2*ChunkSize + 3)
	ref := putTestBlob(t, store, payload)
	single := putTestBlob(t, store, testPayload(100))
	other := sha256.Sum256([]byte("other"))
	records := map[string]BlobRef{
		"unknown version": withRecord(ref, append([]byte{2}, ref.ChunkDigests[1:]...)),
		"short":           withRecord(ref, ref.ChunkDigests[:len(ref.ChunkDigests)-1]),
		"extra chunk":     withRecord(ref, append(bytes.Clone(ref.ChunkDigests), other[:]...)),
		"other blob":      withRecord(ref, append(append([]byte{1}, other[:]...), ref.ChunkDigests[chunkRecordHeader:]...)),
		"header only":     withRecord(ref, ref.ChunkDigests[:chunkRecordHeader]),
		"single chunk":    withRecord(single, append(bytes.Clone(single.ChunkDigests[:chunkRecordHeader]), other[:]...)),
	}
	for name, r := range records {
		blob, err := store.Open(context.Background(), r)
		if err != nil {
			t.Fatalf("%s: open = %v", name, err)
		}
		if blob.RecomputedChunkDigests() == nil {
			t.Fatalf("%s: malformed record was trusted", name)
		}
		blob.Close()
	}
	corruptByte(t, filepath.Join(store.root, ref.StorageKey), 2*ChunkSize+1)
	if _, err := store.Open(context.Background(), records["short"]); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("corrupt blob with malformed record = %v, want integrity error", err)
	}

	// An empty blob's record must carry the digest of no bytes.
	empty := putTestBlob(t, store, nil)
	empty.SHA256 = hex.EncodeToString(other[:])
	empty.ChunkDigests = append([]byte{1}, other[:]...)
	if _, err := store.Open(context.Background(), empty); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("empty blob with wrong digest = %v, want integrity error", err)
	}
}

func TestLocalStoreFileChangedAfterOpen(t *testing.T) {
	store := newTestLocalStore(t)
	payload := testPayload(2*ChunkSize + 9)
	ref := putTestBlob(t, store, payload)
	path := filepath.Join(store.root, ref.StorageKey)

	truncated, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	defer truncated.Close()
	if err := os.Truncate(path, ChunkSize+5); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, ChunkSize)
	if _, err := io.ReadFull(truncated, got); err != nil || !bytes.Equal(got, payload[:ChunkSize]) {
		t.Fatalf("intact chunk of truncated blob = %v", err)
	}
	if n, err := truncated.Read(got); n != 0 || !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("truncated chunk read = %d, %v", n, err)
	}

	// Bytes appended after Open are never read.
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	extended, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	defer extended.Close()
	appendFile(t, path, []byte("appended"))
	if end, err := extended.Seek(0, io.SeekEnd); err != nil || end != ref.Size {
		t.Fatalf("SeekEnd = %d, %v", end, err)
	}
	if _, err := extended.Seek(0, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	all, err := io.ReadAll(extended)
	if err != nil || !bytes.Equal(all, payload) {
		t.Fatalf("extended read %d bytes, err %v", len(all), err)
	}
	if _, err := store.Open(context.Background(), ref); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("open of extended blob = %v, want integrity error", err)
	}
}

func TestLocalStoreBlobSeekBounds(t *testing.T) {
	store := newTestLocalStore(t)
	ref := putTestBlob(t, store, testPayload(ChunkSize+1))
	blob, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := blob.Seek(-1, io.SeekStart); err == nil {
		t.Fatal("negative seek accepted")
	}
	if _, err := blob.Seek(1, io.SeekEnd); err == nil {
		t.Fatal("seek past the end accepted")
	}
	if _, err := blob.Seek(0, 7); err == nil {
		t.Fatal("invalid whence accepted")
	}
	if position, err := blob.Seek(0, io.SeekEnd); err != nil || position != ref.Size {
		t.Fatalf("SeekEnd = %d, %v", position, err)
	}
	if err := blob.VerifyCurrent(); err != nil {
		t.Fatalf("VerifyCurrent at the end = %v", err)
	}
	if n, err := blob.Read(make([]byte, 8)); n != 0 || err != io.EOF {
		t.Fatalf("read at the end = %d, %v", n, err)
	}
	if err := blob.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := blob.Read(make([]byte, 8)); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("read after close = %v", err)
	}
	if blob.Err() != nil {
		t.Fatalf("Err after close = %v", blob.Err())
	}
}

// Run with -race: independent opens of one blob, and one blob used from
// several goroutines (as ServeContent's multi-range writer can) while it is
// closed.
func TestLocalStoreConcurrentReads(t *testing.T) {
	store := newTestLocalStore(t)
	payload := testPayload(5*ChunkSize + 321)
	ref := putTestBlob(t, store, payload)
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for worker := 0; worker < 8; worker++ {
		wg.Add(1)
		go func(seed uint64) {
			defer wg.Done()
			random := rand.New(rand.NewPCG(seed, 7))
			for i := 0; i < 20; i++ {
				blob, err := store.Open(context.Background(), ref)
				if err != nil {
					errs <- err
					return
				}
				start := random.IntN(len(payload))
				length := 1 + random.IntN(len(payload)-start)
				got := make([]byte, length)
				_, seekErr := blob.Seek(int64(start), io.SeekStart)
				_, readErr := io.ReadFull(blob, got)
				blob.Close()
				if seekErr != nil || readErr != nil || !bytes.Equal(got, payload[start:start+length]) {
					errs <- errors.Join(errors.New("range mismatch"), seekErr, readErr)
					return
				}
			}
		}(uint64(worker))
	}
	shared, err := store.Open(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	for reader := 0; reader < 4; reader++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 1000)
			for {
				if _, err := shared.Read(buf); err != nil {
					if !errors.Is(err, io.EOF) && !errors.Is(err, os.ErrClosed) {
						errs <- err
					}
					return
				}
				_ = shared.VerifyCurrent()
				_ = shared.Err()
			}
		}()
	}
	_ = shared.Close()
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
}

func newTestLocalStore(t *testing.T) *LocalStore {
	t.Helper()
	store, err := NewLocalStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func putTestBlob(t *testing.T, store *LocalStore, payload []byte) BlobRef {
	t.Helper()
	ref, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	return ref
}

func withRecord(ref BlobRef, record []byte) BlobRef {
	ref.ChunkDigests = record
	return ref
}

func testPayload(size int) []byte {
	payload := make([]byte, size)
	random := rand.New(rand.NewPCG(uint64(size), 49))
	for i := range payload {
		payload[i] = byte(random.Uint32())
	}
	return payload
}

func corruptByte(t *testing.T, path string, offset int64) {
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

func appendFile(t *testing.T, path string, data []byte) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		t.Fatal(err)
	}
}

func assertRange(t *testing.T, blob Blob, payload []byte, start, length int) {
	t.Helper()
	if _, err := blob.Seek(int64(start), io.SeekStart); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, length)
	if _, err := io.ReadFull(blob, got); err != nil || !bytes.Equal(got, payload[start:start+length]) {
		t.Fatalf("range %d+%d: %v", start, length, err)
	}
}

func assertEmptyDirectory(t *testing.T, path string) {
	t.Helper()
	entries, err := os.ReadDir(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("directory contains %d files", len(entries))
	}
}

type cancelingReader struct {
	cancel context.CancelFunc
	done   bool
}

func (r *cancelingReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, io.EOF
	}
	r.done = true
	copy(p, "partial ciphertext")
	r.cancel()
	return len("partial ciphertext"), nil
}
