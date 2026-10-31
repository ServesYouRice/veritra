package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"

	"private-messenger/server/internal/config"
)

// seedSplitInstance seeds an instance whose blob directory has a different
// parent from its database, as PRIVATE_MESSENGER_STORAGE_PATH allows.
func seedSplitInstance(t *testing.T, label string) (config.Config, string) {
	t.Helper()
	cfg := commandConfig(t.TempDir())
	blobRoot := t.TempDir()
	cfg.StoragePath = filepath.Join(blobRoot, "blobs")
	return seedInstanceAt(t, cfg, label), blobRoot
}

// recordSteps records every fault-hook step, including "sync:<dir>", and
// runs inspect at each one.
func recordSteps(t *testing.T, inspect func(step string) error) *[]string {
	t.Helper()
	var steps []string
	previous := faultHook
	faultHook = func(step string) error {
		steps = append(steps, step)
		if inspect != nil {
			return inspect(step)
		}
		return nil
	}
	t.Cleanup(func() { faultHook = previous })
	return &steps
}

func TestRestoreStagesAndSyncsBlobsOnTheirOwnParent(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	live, blobRoot := seedSplitInstance(t, "original")
	database, _ := filepath.Abs(live.DatabasePath)
	var journal restoreJournal
	steps := recordSteps(t, func(step string) error {
		if step == "restore:activate-blobs" {
			journal = readJournalForTest(t, journalPath(database))
		}
		return nil
	})
	if err := restore(live, []string{archive}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	faultHook = func(string) error { return nil }
	expectLive(t, live, "backup")
	if journal.Version != 2 || filepath.Dir(journal.BlobStagingDir) != blobRoot ||
		!strings.HasPrefix(filepath.Base(journal.BlobStagingDir), ".veritra-restore-blobs-") {
		t.Fatalf("blob staging not under the blob parent: version=%d dir=%q", journal.Version, journal.BlobStagingDir)
	}
	at := func(step string) int {
		index := slices.Index(*steps, step)
		if index < 0 {
			t.Fatalf("step %s never ran: %v", step, *steps)
		}
		return index
	}
	recorded := at("restore:record-activated")
	syncBlobParent := "sync:" + blobRoot
	afterPreserve := slices.Index((*steps)[at("restore:preserve-blobs"):], syncBlobParent)
	afterActivate := slices.Index((*steps)[at("restore:activate-blobs"):], syncBlobParent)
	if afterPreserve < 0 || afterActivate < 0 || at("restore:activate-blobs")+afterActivate > recorded {
		t.Fatalf("blob parent not synced after its renames and before the activated journal: %v", *steps)
	}
	expectNoStaging(t, live.DataDir, blobRoot)
}

func TestSplitLayoutRecoversAndRollsBack(t *testing.T) {
	t.Run("crash while activating blobs", func(t *testing.T) {
		archive := makeBackup(t, seedInstance(t, "backup"))
		live, blobRoot := seedSplitInstance(t, "original")
		withFault(t, "restore:activate-blobs", errSimulatedCrash)
		if err := restore(live, []string{archive}, &bytes.Buffer{}); !errors.Is(err, errSimulatedCrash) {
			t.Fatalf("restore err=%v", err)
		}
		faultHook = func(string) error { return nil }
		steps := recordSteps(t, nil)
		if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
		if !slices.Contains(*steps, "sync:"+blobRoot) {
			t.Fatalf("rollback did not sync the blob parent: %v", *steps)
		}
		expectLive(t, live, "original")
		expectNoStaging(t, live.DataDir, blobRoot)
	})
	t.Run("crash after activation", func(t *testing.T) {
		archive := makeBackup(t, seedInstance(t, "backup"))
		live, blobRoot := seedSplitInstance(t, "original")
		withFault(t, "restore:validate", errSimulatedCrash)
		if err := restore(live, []string{archive}, &bytes.Buffer{}); !errors.Is(err, errSimulatedCrash) {
			t.Fatalf("restore err=%v", err)
		}
		faultHook = func(string) error { return nil }
		if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
		expectLive(t, live, "original")
		expectNoStaging(t, live.DataDir, blobRoot)
	})
	t.Run("validation failure", func(t *testing.T) {
		archive := makeBackup(t, seedInstance(t, "backup"))
		live, blobRoot := seedSplitInstance(t, "original")
		withFault(t, "restore:validate", &os.PathError{Op: "read", Path: "x", Err: syscall.EIO})
		if err := restore(live, []string{archive}, &bytes.Buffer{}); err == nil {
			t.Fatal("restore succeeded although validation failed")
		}
		expectLive(t, live, "original")
		expectNoStaging(t, live.DataDir, blobRoot)
	})
}

// The same-parent layout keeps the journal format older builds can settle.
func TestSameParentLayoutKeepsVersionOneJournals(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	live := seedInstance(t, "original")
	database, _ := filepath.Abs(live.DatabasePath)
	var journal restoreJournal
	recordSteps(t, func(step string) error {
		if step == "restore:activate-blobs" {
			journal = readJournalForTest(t, journalPath(database))
		}
		return nil
	})
	if err := restore(live, []string{archive}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if journal.Version != 1 || journal.BlobStagingDir != "" {
		t.Fatalf("same-parent journal version=%d blob staging=%q", journal.Version, journal.BlobStagingDir)
	}
}
