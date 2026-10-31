package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func readJournalForTest(t *testing.T, path string) restoreJournal {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	var journal restoreJournal
	if err := json.Unmarshal(raw, &journal); err != nil {
		t.Fatal(err)
	}
	return journal
}

// Recovery moves the restored copy into the staging directory before it puts
// the original back, so restore must keep that directory for as long as a
// journal names it.
func TestRestoreKeepsStagingWhileItsJournalRemains(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	live := seedInstance(t, "original")
	withFault(t, "restore:record-activated", &os.PathError{Op: "write", Path: "x", Err: syscall.ENOSPC})
	if err := restore(live, []string{archive}, &bytes.Buffer{}); err == nil {
		t.Fatal("restore succeeded although it could not record the finished state")
	}
	database, _ := filepath.Abs(live.DatabasePath)
	journal := readJournalForTest(t, journalPath(database))
	if journal.State != "activating" {
		t.Fatalf("journal state=%q", journal.State)
	}
	if _, err := os.Stat(filepath.Join(journal.StagingDir, stagingMarkerName)); err != nil {
		t.Fatalf("staging named by the journal was removed: %v", err)
	}
	faultHook = func(string) error { return nil }
	if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
		t.Fatalf("recovery once the fault cleared: %v", err)
	}
	expectLive(t, live, "original")
	expectNoStaging(t, live.DataDir)
}

// An older build could remove staging while its journal stayed. Recovery
// recreates the directory instead of failing on every start.
func TestRecoveryRecreatesAMissingStagingDirectory(t *testing.T) {
	for _, step := range []string{"restore:activate-blobs", "restore:validate"} {
		t.Run(step, func(t *testing.T) {
			live, path := crashRestoreAt(t, step)
			journal := readJournalForTest(t, path)
			if err := os.RemoveAll(journal.StagingDir); err != nil {
				t.Fatal(err)
			}
			if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
				t.Fatalf("recovery without its staging directory: %v", err)
			}
			expectLive(t, live, "original")
			expectNoStaging(t, live.DataDir)
		})
	}
}
