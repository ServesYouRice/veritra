package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

func TestResourceLocksRejectSharedOverriddenPaths(t *testing.T) {
	root := t.TempDir()
	shared := filepath.Join(root, "shared")
	if err := os.MkdirAll(shared, 0o700); err != nil {
		t.Fatal(err)
	}
	// A second spelling of the same directory through a symlink.
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(shared, alias); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	first := config.Config{
		DataDir:      filepath.Join(root, "a"),
		DatabasePath: filepath.Join(shared, "veritra.db"),
		StoragePath:  filepath.Join(root, "a", "blobs"),
	}
	locks, err := acquireResourceLocks(first)
	if err != nil {
		t.Fatal(err)
	}
	sameDatabase := config.Config{
		DataDir:      filepath.Join(root, "b"),
		DatabasePath: filepath.Join(alias, "veritra.db"),
		StoragePath:  filepath.Join(root, "b", "blobs"),
	}
	if _, err := acquireResourceLocks(sameDatabase); err == nil || !strings.Contains(err.Error(), "multiple writers") {
		t.Fatalf("shared database accepted: %v", err)
	}
	sameBlobs := config.Config{
		DataDir:      filepath.Join(root, "c"),
		DatabasePath: filepath.Join(root, "c", "veritra.db"),
		StoragePath:  filepath.Join(root, "a", ".", "blobs"),
	}
	if _, err := acquireResourceLocks(sameBlobs); err == nil || !strings.Contains(err.Error(), "multiple writers") {
		t.Fatalf("shared blob directory accepted: %v", err)
	}
	if err := locks.Release(); err != nil {
		t.Fatal(err)
	}
	again, err := acquireResourceLocks(sameDatabase)
	if err != nil {
		t.Fatalf("released locks could not be reacquired: %v", err)
	}
	if err := again.Release(); err != nil {
		t.Fatal(err)
	}
}

func TestResourceLayoutRejectsOverlap(t *testing.T) {
	root := t.TempDir()
	cases := []config.Config{
		{DataDir: root, DatabasePath: filepath.Join(root, "blobs", "veritra.db"), StoragePath: filepath.Join(root, "blobs")},
		{DataDir: root, DatabasePath: filepath.Join(root, "veritra.db"), StoragePath: root},
		{DataDir: filepath.Join(root, "blobs", "data"), DatabasePath: filepath.Join(root, "veritra.db"), StoragePath: filepath.Join(root, "blobs")},
	}
	for _, cfg := range cases {
		if locks, err := acquireResourceLocks(cfg); err == nil {
			_ = locks.Release()
			t.Fatalf("overlapping layout accepted: %+v", cfg)
		}
	}
}
