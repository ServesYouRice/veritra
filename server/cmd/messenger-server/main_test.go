package main

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

func TestInstanceLockRejectsSecondWriter(t *testing.T) {
	dir := t.TempDir()
	first, err := acquireInstanceLock(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := acquireInstanceLock(dir); err == nil || !strings.Contains(err.Error(), "multiple writers") {
		t.Fatalf("second lock error=%v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatal(err)
	}
	second, err := acquireInstanceLock(dir)
	if err != nil {
		t.Fatalf("released lock could not be reacquired: %v", err)
	}
	if err := second.Release(); err != nil {
		t.Fatal(err)
	}
}

func TestInstanceLockIgnoresStaleLockFileWithoutHolder(t *testing.T) {
	dir := t.TempDir()
	// A hard crash (SIGKILL, OOM, node loss) leaves the file behind but the
	// kernel has already dropped the advisory lock.
	stale := "pid=999999\nstarted_at=2000-01-01T00:00:00Z\nleftover-padding-from-older-format\n"
	path := filepath.Join(dir, instanceLockName)
	if err := os.WriteFile(path, []byte(stale), 0o600); err != nil {
		t.Fatal(err)
	}
	lock, err := acquireInstanceLock(dir)
	if err != nil {
		t.Fatalf("stale lock file blocked startup: %v", err)
	}
	if _, err := acquireInstanceLock(dir); err == nil || !strings.Contains(err.Error(), "multiple writers") {
		t.Fatalf("second lock while held error=%v", err)
	}
	if err := lock.Release(); err != nil {
		t.Fatal(err)
	}
	// Read after release: Windows byte-range locks block other readers while held.
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "999999") || strings.Contains(string(raw), "leftover") || !strings.Contains(string(raw), "pid=") {
		t.Fatalf("lock file not rewritten: %q", raw)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("lock file should be kept after release: %v", err)
	}
	if err := lock.Release(); err != nil {
		t.Fatalf("double release: %v", err)
	}
}

func TestGenerateSetupTokenProducesValidToken(t *testing.T) {
	var output bytes.Buffer
	if err := generateSetupToken(&output); err != nil {
		t.Fatal(err)
	}
	if err := config.ValidateSetupToken(strings.TrimSpace(output.String())); err != nil {
		t.Fatalf("generated token rejected: %v", err)
	}
}

func TestOffHostBackupRestoresOnCleanHost(t *testing.T) {
	ctx := context.Background()
	source := commandConfig(t.TempDir())
	if err := migrate(ctx, source, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	offHostBackup := filepath.Join(t.TempDir(), "off-host", "backup")
	if err := backup(ctx, source, []string{offHostBackup}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	destination := commandConfig(t.TempDir())
	if err := restore(destination, []string{offHostBackup}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := doctor(ctx, destination, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "storage: ok") {
		t.Fatalf("doctor output=%q", output.String())
	}
}

func TestDoctorWarnsWhenBlobsReachTheInstanceLimit(t *testing.T) {
	ctx := context.Background()
	cfg := commandConfig(t.TempDir())
	cfg.Limits.InstanceStorageBytes = 64 << 20
	cfg.Limits.AccountStorageBytes = 16 << 20
	if err := migrate(ctx, cfg, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := doctor(ctx, cfg, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "encrypted storage: 0 MiB of 64 MiB instance limit (configured)") || strings.Contains(output.String(), "warning:") {
		t.Fatalf("doctor output=%q", output.String())
	}
	db, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`UPDATE blob_usage_instance SET size_bytes = ? WHERE id = 1`, int64(64<<20)); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err := doctor(ctx, cfg, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "warning: stored blobs reach the instance storage limit") {
		t.Fatalf("doctor output=%q", output.String())
	}
}

func commandConfig(dir string) config.Config {
	return config.Config{
		Addr:         "127.0.0.1:0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Deployment Test",
		Environment:  "development",
	}
}
