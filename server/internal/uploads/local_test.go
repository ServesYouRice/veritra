package uploads

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestLocalStorePutSyncsAndOpenValidates(t *testing.T) {
	store := newTestLocalStore(t)
	payload := []byte("encrypted bytes")
	key, digest, size, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	file, err := store.Open(context.Background(), key, digest, size)
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
			if _, _, _, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader([]byte("ciphertext"))); err == nil {
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
	if _, _, _, err := store.PutEncryptedBlob(ctx, reader); !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context canceled", err)
	}
	assertEmptyDirectory(t, store.root)
}

func TestLocalStoreOpenRejectsTruncatedOrCorruptBlob(t *testing.T) {
	store := newTestLocalStore(t)
	payload := []byte("encrypted bytes")
	key, digest, size, err := store.PutEncryptedBlob(context.Background(), bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.root, key)
	if err := os.Truncate(path, size-1); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Open(context.Background(), key, digest, size); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("truncated error = %v, want integrity error", err)
	}
	if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, int(size)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Open(context.Background(), key, digest, size); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("corrupt error = %v, want integrity error", err)
	}
	badDigest := sha256.Sum256([]byte("different"))
	if _, err := store.Open(context.Background(), key, hex.EncodeToString(badDigest[:]), size); !errors.Is(err, ErrBlobIntegrity) {
		t.Fatalf("digest error = %v, want integrity error", err)
	}
}

func TestLocalStoreRejectsUnsafeStorageKey(t *testing.T) {
	store := newTestLocalStore(t)
	if _, err := store.Open(context.Background(), "../blob_example", "", 0); !errors.Is(err, ErrInvalidStorageKey) {
		t.Fatalf("error = %v, want invalid storage key", err)
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
