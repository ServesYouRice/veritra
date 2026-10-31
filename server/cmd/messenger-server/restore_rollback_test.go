package main

import (
	"bytes"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"private-messenger/server/internal/config"
)

const rollbackSuffix = ".pre-restore-20261025T000000Z-abc"

// interruptedRestoreWithWAL leaves the state of a restore killed after
// activation: the original database, its WAL holding a committed row that the
// database file lacks, and its blobs sit at their rollback paths, while the
// restored database and blobs are live.
func interruptedRestoreWithWAL(t *testing.T) (config.Config, string) {
	t.Helper()
	archive := makeBackup(t, seedInstance(t, "backup"))
	cfg := seedInstance(t, "original")
	live, _ := filepath.Abs(cfg.DatabasePath)
	liveBlobs, _ := filepath.Abs(cfg.StoragePath)

	db, err := sql.Open("sqlite", live)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	for _, statement := range []string{
		`PRAGMA journal_mode=WAL`, `PRAGMA wal_autocheckpoint=0`,
		`CREATE TABLE wal_marker(value TEXT NOT NULL)`, `INSERT INTO wal_marker(value) VALUES('committed in the WAL')`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	// Copy the files while the connection is open: a killed server leaves
	// exactly this, and closing would checkpoint the WAL away.
	main, err := os.ReadFile(live)
	if err != nil {
		t.Fatal(err)
	}
	wal, err := os.ReadFile(live + "-wal")
	if err != nil || len(wal) == 0 {
		t.Fatalf("no WAL to preserve: %v", err)
	}
	db.Close()
	_ = os.Remove(live + "-wal")
	_ = os.Remove(live + "-shm")
	if err := os.WriteFile(live+rollbackSuffix, main, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(live+"-wal"+rollbackSuffix, wal, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(liveBlobs, liveBlobs+rollbackSuffix); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(filepath.Join(archive, "database.db"), live, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(liveBlobs, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(filepath.Join(archive, "blobs", "blob_1"), filepath.Join(liveBlobs, "blob_1"), 0o600); err != nil {
		t.Fatal(err)
	}
	stage, err := makeStagingDir(filepath.Dir(live), ".veritra-restore-")
	if err != nil {
		t.Fatal(err)
	}
	path := journalPath(live)
	if err := writeJournal(path, restoreJournal{
		Version: 1, State: "activating", Database: live, DatabaseRollback: live + rollbackSuffix,
		Companions: map[string]string{live + "-wal": live + "-wal" + rollbackSuffix},
		Blobs:      liveBlobs, BlobsRollback: liveBlobs + rollbackSuffix, StagingDir: stage,
	}); err != nil {
		t.Fatal(err)
	}
	return cfg, path
}

func walMarkerRows(t *testing.T, cfg config.Config) int {
	t.Helper()
	db, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var rows int
	if err := db.QueryRow(`SELECT COUNT(*) FROM wal_marker`).Scan(&rows); err != nil {
		t.Fatalf("read the original WAL's row: %v", err)
	}
	return rows
}

// SQLite does not check that a WAL belongs to the database beside it, so a
// rollback that could not put the original database back must leave the
// original WAL (and the blobs) where they are.
func TestRollbackStopsWhenTheDatabaseCannotBePutBack(t *testing.T) {
	cfg, path := interruptedRestoreWithWAL(t)
	live, _ := filepath.Abs(cfg.DatabasePath)
	liveBlobs, _ := filepath.Abs(cfg.StoragePath)
	withFault(t, "restore:rollback-database", &os.PathError{Op: "rename", Path: live, Err: syscall.EACCES})
	if err := recoverInterruptedRestore(cfg, &bytes.Buffer{}); err == nil {
		t.Fatal("recovery reported success although the database stayed restored")
	}
	if _, err := os.Lstat(live + "-wal"); !os.IsNotExist(err) {
		t.Fatalf("a WAL sits beside the restored database: %v", err)
	}
	for _, kept := range []string{live + "-wal" + rollbackSuffix, live + rollbackSuffix, liveBlobs + rollbackSuffix, path} {
		if _, err := os.Lstat(kept); err != nil {
			t.Fatalf("%s moved: %v", kept, err)
		}
	}
	expectLive(t, cfg, "backup")

	faultHook = func(string) error { return nil }
	if err := recoverInterruptedRestore(cfg, &bytes.Buffer{}); err != nil {
		t.Fatalf("retried recovery: %v", err)
	}
	expectLive(t, cfg, "original")
	if rows := walMarkerRows(t, cfg); rows != 1 {
		t.Fatalf("original WAL rows=%d, want 1", rows)
	}
	expectNoStaging(t, cfg.DataDir)
}

// A retried rollback finds what an earlier attempt left in staging; the
// names it moves restored copies to must not collide with those.
func TestRollbackRetryDoesNotCollideInStaging(t *testing.T) {
	cfg, path := interruptedRestoreWithWAL(t)
	live, _ := filepath.Abs(cfg.DatabasePath)
	journal := readJournalForTest(t, path)
	for _, name := range []string{"rolled-back-" + filepath.Base(live), "rolled-back-" + filepath.Base(cfg.StoragePath)} {
		occupied := filepath.Join(journal.StagingDir, name)
		if err := os.MkdirAll(filepath.Join(occupied, "earlier attempt"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := recoverInterruptedRestore(cfg, &bytes.Buffer{}); err != nil {
		t.Fatalf("recovery with an occupied staging name: %v", err)
	}
	expectLive(t, cfg, "original")
	if rows := walMarkerRows(t, cfg); rows != 1 {
		t.Fatalf("original WAL rows=%d, want 1", rows)
	}
	expectNoStaging(t, cfg.DataDir)
}

// restore's own rollback keeps the journal and staging when it fails, so the
// next command can finish it.
func TestRestoreRollbackFailureLeavesARecoverableJournal(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	live := seedInstance(t, "original")
	failure := &os.PathError{Op: "rename", Path: "x", Err: syscall.EACCES}
	previous := faultHook
	faultHook = func(step string) error {
		if step == "restore:validate" || step == "restore:rollback-database" {
			return failure
		}
		return nil
	}
	t.Cleanup(func() { faultHook = previous })
	if err := restore(live, []string{archive}, &bytes.Buffer{}); !errors.Is(err, failure) {
		t.Fatalf("restore err=%v", err)
	}
	database, _ := filepath.Abs(live.DatabasePath)
	journal := readJournalForTest(t, journalPath(database))
	if _, err := os.Stat(filepath.Join(journal.StagingDir, stagingMarkerName)); err != nil {
		t.Fatalf("staging named by the journal was removed: %v", err)
	}
	faultHook = func(string) error { return nil }
	if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	expectLive(t, live, "original")
	expectNoStaging(t, live.DataDir)
}
