package main

import (
	"bytes"
	"context"
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
