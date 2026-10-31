package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// A restore killed while it validates the restored database can leave that
// database's -wal and -shm at the live paths. The original had none, so the
// journal lists none; the rollback must still take them away before the
// original database goes back, or SQLite would pair them with it.
func TestRollbackWithdrawsRestoredCompanionsTheJournalDoesNotList(t *testing.T) {
	cfg, journalFile := crashRestoreAt(t, "restore:validate")
	live, _ := filepath.Abs(cfg.DatabasePath)

	raw, err := os.ReadFile(journalFile)
	if err != nil {
		t.Fatal(err)
	}
	var journal restoreJournal
	if err := json.Unmarshal(raw, &journal); err != nil {
		t.Fatal(err)
	}
	if len(journal.Companions) != 0 {
		t.Fatalf("journal lists companions %v; this test needs an original without them", journal.Companions)
	}

	// Leave a real WAL of the restored database, as a killed connection
	// would: copy it while the connection is open, then put it back.
	db, err := sql.Open("sqlite", live)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	for _, statement := range []string{
		`PRAGMA journal_mode=WAL`, `PRAGMA wal_autocheckpoint=0`,
		`INSERT INTO drill_marker(value) VALUES('restored WAL')`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	residue := map[string][]byte{}
	for _, companion := range []string{live + "-wal", live + "-shm"} {
		data, err := os.ReadFile(companion)
		if err != nil || len(data) == 0 {
			t.Fatalf("no %s to leave behind: %v", companion, err)
		}
		residue[companion] = data
	}
	db.Close()
	for companion, data := range residue {
		if err := os.WriteFile(companion, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if err := recoverInterruptedRestore(cfg, &bytes.Buffer{}); err != nil {
		t.Fatalf("recovery: %v", err)
	}
	for companion := range residue {
		if _, err := os.Lstat(companion); !os.IsNotExist(err) {
			t.Fatalf("restored companion %s left beside the original database: %v", companion, err)
		}
	}
	expectLive(t, cfg, "original")
}
