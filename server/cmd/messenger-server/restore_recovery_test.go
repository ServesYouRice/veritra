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

// crashRestoreAt leaves an "activating" journal behind, as a killed restore
// would, and returns the live configuration and its journal path.
func crashRestoreAt(t *testing.T, step string) (config.Config, string) {
	t.Helper()
	archive := makeBackup(t, seedInstance(t, "backup"))
	cfg := seedInstance(t, "original")
	withFault(t, step, errSimulatedCrash)
	if err := restore(cfg, []string{archive}, &bytes.Buffer{}); !errors.Is(err, errSimulatedCrash) {
		t.Fatalf("restore err=%v, want a simulated crash", err)
	}
	faultHook = func(string) error { return nil }
	database, err := filepath.Abs(cfg.DatabasePath)
	if err != nil {
		t.Fatal(err)
	}
	return cfg, journalPath(database)
}

// onRecoveryLocked runs action at the moment recovery holds the restore lock.
func onRecoveryLocked(t *testing.T, action func()) {
	t.Helper()
	previous := faultHook
	faultHook = func(step string) error {
		if step == "recover:locked" {
			action()
		}
		return nil
	}
	t.Cleanup(func() { faultHook = previous })
}

// A restore that finishes between recovery's journal check and its lock
// removes the journal; recovery must then move nothing.
func TestRecoveryActsOnlyOnTheJournalReadUnderTheLock(t *testing.T) {
	t.Run("journal removed", func(t *testing.T) {
		live, journal := crashRestoreAt(t, "restore:validate")
		onRecoveryLocked(t, func() {
			if err := os.Remove(journal); err != nil {
				t.Error(err)
			}
		})
		if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
			t.Fatalf("recovery after the journal went away: %v", err)
		}
		expectLive(t, live, "backup")
	})
	t.Run("journal now activated", func(t *testing.T) {
		live, journal := crashRestoreAt(t, "restore:validate")
		onRecoveryLocked(t, func() {
			raw, err := os.ReadFile(journal)
			if err != nil {
				t.Error(err)
				return
			}
			updated := strings.Replace(string(raw), `"state": "activating"`, `"state": "activated"`, 1)
			if updated == string(raw) {
				t.Errorf("journal has no activating state: %s", raw)
			}
			if err := os.WriteFile(journal, []byte(updated), 0o600); err != nil {
				t.Error(err)
			}
		})
		var output bytes.Buffer
		if err := recoverInterruptedRestore(live, &output); err != nil {
			t.Fatalf("recovery of a finished restore: %v", err)
		}
		expectLive(t, live, "backup")
		if _, err := os.Lstat(journal); !os.IsNotExist(err) {
			t.Fatalf("journal still present: %v", err)
		}
		if !strings.Contains(output.String(), "had finished") {
			t.Fatalf("output=%q", output.String())
		}
		expectNoStaging(t, filepath.Dir(journal))
	})
}

func TestRecoveryWithoutAJournalTakesNoLock(t *testing.T) {
	cfg := seedInstance(t, "original")
	if err := recoverInterruptedRestore(cfg, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	database, _ := filepath.Abs(cfg.DatabasePath)
	if _, err := os.Lstat(database + ".restore.lock"); !os.IsNotExist(err) {
		t.Fatalf("recovery without a journal created the restore lock: %v", err)
	}
}
