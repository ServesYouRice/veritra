package uploads

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLocalStoreDeleteSyncsTheDirectory(t *testing.T) {
	store := newTestLocalStore(t)
	ref := putTestBlob(t, store, []byte("ciphertext to delete"))
	var synced []string
	store.syncDirectory = func(path string) error { synced = append(synced, path); return nil }
	if err := store.Delete(context.Background(), ref.StorageKey); err != nil {
		t.Fatal(err)
	}
	if len(synced) != 1 || synced[0] != store.root {
		t.Fatalf("directory syncs after a delete = %v, want one of the blob root", synced)
	}
	if _, err := os.Stat(filepath.Join(store.root, ref.StorageKey)); !os.IsNotExist(err) {
		t.Fatalf("blob still there (stat err = %v)", err)
	}

	// A failed flush is a failed delete: the caller keeps the key queued.
	ref = putTestBlob(t, store, []byte("another ciphertext"))
	boom := errors.New("directory sync failed")
	store.syncDirectory = func(string) error { return boom }
	if err := store.Delete(context.Background(), ref.StorageKey); !errors.Is(err, boom) {
		t.Fatalf("delete with a failing directory sync: err = %v, want it returned", err)
	}

	// A blob that is already gone is deleted again when the sync works.
	store.syncDirectory = func(string) error { return nil }
	if err := store.Delete(context.Background(), ref.StorageKey); err != nil {
		t.Fatalf("delete of a missing blob: %v", err)
	}
	if err := store.Delete(context.Background(), ref.StorageKey); err != nil {
		t.Fatalf("second delete of a missing blob: %v", err)
	}
}

// vanishingEntry is a listed file whose Info fails the way lstat does once the
// file was renamed or removed after the directory was read.
type vanishingEntry struct{ name string }

func (e vanishingEntry) Name() string      { return e.name }
func (e vanishingEntry) IsDir() bool       { return false }
func (e vanishingEntry) Type() fs.FileMode { return 0 }
func (e vanishingEntry) Info() (fs.FileInfo, error) {
	return nil, &fs.PathError{Op: "lstat", Path: e.name, Err: fs.ErrNotExist}
}

func TestCleanupTemporaryFilesKeepsSweepingWhenAListedFileVanishes(t *testing.T) {
	store := newTestLocalStore(t)
	stale := filepath.Join(store.root, "blob_stale.tmp")
	fresh := filepath.Join(store.root, "blob_fresh.tmp")
	for _, path := range []string{stale, fresh} {
		if err := os.WriteFile(path, []byte("partial"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	listed, err := os.ReadDir(store.root)
	if err != nil {
		t.Fatal(err)
	}
	// The vanished entry comes first, so a sweep that stops at it removes
	// nothing.
	entries := append([]os.DirEntry{vanishingEntry{"blob_gone.tmp"}}, listed...)
	removed, err := store.sweepTemporaryEntries(context.Background(), entries, time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if removed != 1 {
		t.Fatalf("removed = %d, want only the stale file that this sweep removed", removed)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("stale temporary file kept (stat err = %v)", err)
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("fresh temporary file removed: %v", err)
	}
}

func TestCleanupTemporaryFilesDoesNotCountFilesAnotherSweepRemoved(t *testing.T) {
	store := newTestLocalStore(t)
	stale := filepath.Join(store.root, "blob_race.tmp")
	if err := os.WriteFile(stale, []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	// Another sweep removes the file between this one's age check and its
	// removal.
	store.remove = func(path string) error {
		_ = os.Remove(path)
		return os.Remove(path)
	}
	removed, err := store.CleanupTemporaryFiles(context.Background(), time.Now().Add(-time.Hour))
	if err != nil || removed != 0 {
		t.Fatalf("sweep = (%d, %v), want a file someone else removed to be skipped, not counted", removed, err)
	}

	// Other errors still stop the sweep and are returned.
	if err := os.WriteFile(stale, []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	boom := errors.New("permission denied")
	store.remove = func(string) error { return boom }
	if _, err := store.CleanupTemporaryFiles(context.Background(), time.Now().Add(-time.Hour)); !errors.Is(err, boom) {
		t.Fatalf("sweep with a failing removal: err = %v, want it returned", err)
	}
}
