package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// writeSyntheticManifest writes a manifest the way backup() does, with
// blobs entries shaped like real ones (blob_<32 hex> keys, 64-hex digests,
// 8-digit sizes), and returns its size.
func writeSyntheticManifest(t *testing.T, dir string, blobs int) int {
	t.Helper()
	manifest := instanceBackupManifest{
		Version: backupFormat, CreatedAt: time.Now().UTC(), ProducedBy: "veritra-server test",
		InstanceName: "large", DatabaseFile: "database.db", DatabaseSHA256: strings.Repeat("a", 64),
		Migrations: []string{"0001_init.sql"},
	}
	for i := range blobs {
		manifest.Blobs = append(manifest.Blobs, backupManifestBlob{
			StorageKey: fmt.Sprintf("blob_%032x", i), SHA256: fmt.Sprintf("%064x", i), SizeBytes: 26_214_400,
		})
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return len(raw)
}

// Every manifest backup() can publish must pass restore's check; at 1 MiB
// that stopped near 6,000 attachments.
func TestBackupManifestLimitAdmitsLargeInstances(t *testing.T) {
	dir := t.TempDir()
	size := writeSyntheticManifest(t, dir, 20_000)
	t.Logf("20000 blob entries: %d bytes, %d bytes per entry; limit %d bytes holds about %d entries",
		size, size/20_000, maxBackupManifestBytes, maxBackupManifestBytes/int64(size/20_000))
	manifest, err := readAndValidateBackupManifest(dir)
	if err != nil {
		t.Fatalf("a 20,000-blob manifest was rejected: %v", err)
	}
	if len(manifest.Blobs) != 20_000 {
		t.Fatalf("read %d blobs", len(manifest.Blobs))
	}
}

func lowerManifestLimit(t *testing.T, limit int64) {
	t.Helper()
	previous := maxBackupManifestBytes
	maxBackupManifestBytes = limit
	t.Cleanup(func() { maxBackupManifestBytes = previous })
}

func TestBackupManifestOverTheLimitIsRefused(t *testing.T) {
	lowerManifestLimit(t, 4096)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), bytes.Repeat([]byte(" "), 4097), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readAndValidateBackupManifest(dir); err == nil || !strings.Contains(err.Error(), "backup manifest is too large") {
		t.Fatalf("err=%v, want too large", err)
	}
}

// The size check must not need the whole file in memory first.
func TestBackupManifestReadIsBounded(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.json")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	// Sparse: no disk space is used.
	if err := file.Truncate(512 << 20); err != nil {
		t.Fatal(err)
	}
	file.Close()
	lowerManifestLimit(t, 1<<20)
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	_, err = readAndValidateBackupManifest(dir)
	runtime.ReadMemStats(&after)
	if err == nil || !strings.Contains(err.Error(), "backup manifest is too large") {
		t.Fatalf("err=%v, want too large", err)
	}
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > 64<<20 {
		t.Fatalf("checking a 512 MiB manifest allocated %d bytes", allocated)
	}
}

func TestBackupRefusesAManifestRestoreWouldReject(t *testing.T) {
	source := seedInstance(t, "backup")
	lowerManifestLimit(t, 256)
	parent := t.TempDir()
	out := filepath.Join(parent, "backup")
	err := backup(context.Background(), source, []string{out}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "exceeds the restorable limit") {
		t.Fatalf("backup err=%v, want the manifest limit", err)
	}
	if _, err := os.Lstat(out); !os.IsNotExist(err) {
		t.Fatalf("a backup restore would reject was published: %v", err)
	}
	expectNoStaging(t, parent)
}
