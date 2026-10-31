package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A running server holds the data-directory lock and the database lock for
// its whole life, idle or not. restore and reset-owner-password must find
// those held and stop; SQLite's own locks cannot tell an idle server.

func writePasswordFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "password")
	if err := os.WriteFile(path, []byte("correct horse battery staple 2026\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRestoreRefusesWhileAServerHoldsItsLocks(t *testing.T) {
	ctx := context.Background()
	live := seedInstance(t, "live")
	other := seedInstance(t, "backup")
	archive := filepath.Join(t.TempDir(), "backup")
	if err := backup(ctx, other, []string{archive}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	t.Run("data directory lock", func(t *testing.T) {
		server, err := acquireInstanceLock(live.DataDir)
		if err != nil {
			t.Fatal(err)
		}
		defer server.Release()
		err = restore(live, []string{archive}, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), "stop the server") {
			t.Fatalf("restore with a server running: err = %v, want a refusal to stop the server first", err)
		}
		expectLive(t, live, "live")
	})
	t.Run("database lock of another data directory", func(t *testing.T) {
		server, err := acquireResourceLocks(live)
		if err != nil {
			t.Fatal(err)
		}
		defer server.Release()
		err = restore(live, []string{archive}, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), "stop the server") {
			t.Fatalf("restore with a server on the database: err = %v, want a refusal to stop the server first", err)
		}
		expectLive(t, live, "live")
	})
	t.Run("no server", func(t *testing.T) {
		if err := restore(live, []string{archive}, &bytes.Buffer{}); err != nil {
			t.Fatalf("restore with no server running: %v", err)
		}
		expectLive(t, live, "backup")
		// The locks are not kept after the command.
		again, err := acquireInstanceLock(live.DataDir)
		if err != nil {
			t.Fatalf("instance lock still held after restore: %v", err)
		}
		again.Release()
	})
}

func TestResetOwnerPasswordRefusesWhileAServerHoldsItsLocks(t *testing.T) {
	ctx := context.Background()
	cfg := seedInstance(t, "live")
	passwordFile := writePasswordFile(t)
	server, err := acquireInstanceLock(cfg.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	err = resetOwnerPassword(ctx, cfg, "owner", passwordFile, &bytes.Buffer{})
	server.Release()
	if err == nil || !strings.Contains(err.Error(), "stop the server") {
		t.Fatalf("reset with a server running: err = %v, want a refusal to stop the server first", err)
	}
	var output bytes.Buffer
	if err := resetOwnerPassword(ctx, cfg, "owner", passwordFile, &output); err != nil {
		t.Fatalf("reset with no server running: %v", err)
	}
	if !strings.Contains(output.String(), "owner password reset") {
		t.Fatalf("reset output = %q", output.String())
	}
}

func TestResetOwnerPasswordOnAMissingDatabaseCreatesNothing(t *testing.T) {
	cfg := commandConfig(t.TempDir())
	err := resetOwnerPassword(context.Background(), cfg, "owner", writePasswordFile(t), &bytes.Buffer{})
	if err == nil {
		t.Fatal("reset succeeded without a database")
	}
	if _, statErr := os.Stat(cfg.DatabasePath); !os.IsNotExist(statErr) {
		t.Fatalf("reset created %s (stat err = %v)", cfg.DatabasePath, statErr)
	}
}

// The scheduled backup runs its restore drill beside a live server. The drill
// restores into its own scratch data directory, so the locks the server holds
// on the live one must not stop it.
func TestRestoreDrillRunsWhileAServerHoldsTheLiveLocks(t *testing.T) {
	ctx := context.Background()
	live := seedInstance(t, "live")
	archive := filepath.Join(t.TempDir(), "backup")
	if err := backup(ctx, live, []string{archive}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	instance, err := acquireInstanceLock(live.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Release()
	resources, err := acquireResourceLocks(live)
	if err != nil {
		t.Fatal(err)
	}
	defer resources.Release()
	var output bytes.Buffer
	if err := verifyBackup(ctx, live, []string{archive}, &output); err != nil {
		t.Fatalf("restore drill beside a running server: %v", err)
	}
	if !strings.Contains(output.String(), "backup verified") {
		t.Fatalf("drill output = %q", output.String())
	}
}

// A mistyped data directory must not be created by the command: the database
// is looked for before any lock file is.
func TestResetOwnerPasswordOnAMistypedPathCreatesNoDirectoryOrLockFile(t *testing.T) {
	cfg := commandConfig(filepath.Join(t.TempDir(), "typo"))
	err := resetOwnerPassword(context.Background(), cfg, "owner", writePasswordFile(t), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "no database") {
		t.Fatalf("reset on a missing database: err = %v, want a no-database error", err)
	}
	if _, statErr := os.Stat(cfg.DataDir); !os.IsNotExist(statErr) {
		t.Fatalf("reset created the data directory %s (stat err = %v)", cfg.DataDir, statErr)
	}
}
