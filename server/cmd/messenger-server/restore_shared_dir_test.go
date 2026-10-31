package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

// sharedDirInstances seeds two instances whose database files share one
// parent directory, and so share one restore journal path. Their data and
// blob directories are separate, so only the journal directory is shared.
func sharedDirInstances(t *testing.T) (config.Config, config.Config) {
	t.Helper()
	shared := t.TempDir()
	instance := func(name string) config.Config {
		cfg := commandConfig(t.TempDir())
		cfg.DatabasePath = filepath.Join(shared, name+".db")
		return seedInstanceAt(t, cfg, name)
	}
	return instance("a"), instance("b")
}

// A restore of one database must not run while another restore holds the
// journal of the same directory: it would overwrite or delete that journal.
func TestRestoreRefusesWhileAnotherDatabaseInTheDirectoryRestores(t *testing.T) {
	first, second := sharedDirInstances(t)
	archive := makeBackup(t, seedInstance(t, "backup"))
	var nested error
	ran := false
	previous := faultHook
	t.Cleanup(func() { faultHook = previous })
	faultHook = func(step string) error {
		if step == "restore:stage-blob" && !ran {
			ran = true
			// The second restore has checked for a journal and is about to
			// write its own: the first must not start now.
			nested = restore(first, []string{archive}, &bytes.Buffer{})
		}
		return nil
	}
	if err := restore(second, []string{archive}, &bytes.Buffer{}); err != nil {
		t.Fatalf("outer restore: %v", err)
	}
	if !ran {
		t.Fatal("nested restore did not run")
	}
	if nested == nil || !strings.Contains(nested.Error(), "another restore is active in this directory") {
		t.Fatalf("nested restore err=%v, want the directory restore lock refusal", nested)
	}
	expectLive(t, first, "a")
	expectLive(t, second, "backup")
}

// Recovery must not act on the shared journal while another database's
// restore in the same directory holds it.
func TestRecoveryRefusesWhileTheDirectoryRestoreLockIsHeld(t *testing.T) {
	cfg, journal := crashRestoreAt(t, "restore:validate")
	before, err := os.ReadFile(journal)
	if err != nil {
		t.Fatal(err)
	}
	database, _ := filepath.Abs(cfg.DatabasePath)
	held, err := acquireRestoreDirLock(database)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Release()
	err = recoverInterruptedRestore(cfg, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "another restore is active in this directory") {
		t.Fatalf("recovery err=%v, want the directory restore lock refusal", err)
	}
	after, err := os.ReadFile(journal)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("journal changed while another restore held the directory: %v", err)
	}
	expectLive(t, cfg, "backup")
	if err := held.Release(); err != nil {
		t.Fatal(err)
	}
	if err := recoverInterruptedRestore(cfg, &bytes.Buffer{}); err != nil {
		t.Fatalf("recovery once the directory is free: %v", err)
	}
	expectLive(t, cfg, "original")
}

func TestRecoveryWithoutAJournalTakesNoDirectoryLock(t *testing.T) {
	cfg := seedInstance(t, "original")
	if err := recoverInterruptedRestore(cfg, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	database, _ := filepath.Abs(cfg.DatabasePath)
	if _, err := os.Lstat(filepath.Join(filepath.Dir(database), restoreDirLockName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("recovery without a journal created the directory restore lock: %v", err)
	}
}
