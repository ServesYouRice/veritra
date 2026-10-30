package uploads

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPreparedWriteGuardPrecedesRegistrationAndSurvivesRename(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	s, err := NewLocalStore(root)
	if err != nil {
		t.Fatal(err)
	}
	var key string
	w, err := s.PrepareEncryptedBlob(ctx, func(k string) error {
		key = k
		if err := s.Delete(ctx, k); !errors.Is(err, ErrBlobBusy) {
			t.Fatalf("registration guard: %v", err)
		}
		entries, err := os.ReadDir(root)
		if err != nil || len(entries) != 0 {
			t.Fatalf("file before registration: %v %v", entries, err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	ref, err := w.Write(ctx, bytes.NewReader([]byte("opaque ciphertext")))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(ctx, key); !errors.Is(err, ErrBlobBusy) {
		t.Fatalf("renamed guard: %v", err)
	}
	if _, err := w.Write(ctx, bytes.NewReader(nil)); err == nil {
		t.Fatal("write reused")
	}
	if _, err := os.Stat(filepath.Join(root, ref.StorageKey)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(ctx, key); err != nil {
		t.Fatal(err)
	}
}

func TestPreparedRegistrationFailureCreatesNoFileAndReleasesGuard(t *testing.T) {
	s, err := NewLocalStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	expected := errors.New("durable registration failed")
	var key string
	_, err = s.PrepareEncryptedBlob(context.Background(), func(k string) error { key = k; return expected })
	if !errors.Is(err, expected) {
		t.Fatal(err)
	}
	if err := s.Delete(context.Background(), key); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(s.root)
	if len(entries) != 0 {
		t.Fatal(entries)
	}
}

func TestPreparedTemporaryCleanupSkipsGuardedFile(t *testing.T) {
	s, err := NewLocalStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var key string
	w, err := s.PrepareEncryptedBlob(context.Background(), func(k string) error { key = k; return nil })
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(s.root, key+".tmp")
	if err := os.WriteFile(p, []byte("partial ciphertext"), 0600); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Hour)
	n, err := s.CleanupTemporaryFiles(context.Background(), future)
	if err != nil || n != 0 {
		t.Fatalf("guarded temp removed: %d %v", n, err)
	}
	_ = w.Close()
	n, err = s.CleanupTemporaryFiles(context.Background(), future)
	if err != nil || n != 1 {
		t.Fatalf("abandoned temp retained: %d %v", n, err)
	}
}
