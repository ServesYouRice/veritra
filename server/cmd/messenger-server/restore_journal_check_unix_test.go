//go:build !windows

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A journal path that cannot be resolved (here a symlink loop, which Stat
// reports as ELOOP rather than "not exist") must stop a restore, not be
// read as "no earlier restore".
func TestRestoreRefusesAJournalItCannotCheck(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	cfg := seedInstance(t, "original")
	database, _ := filepath.Abs(cfg.DatabasePath)
	journal := journalPath(database)
	if err := os.Symlink(journal, journal); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	err := restore(cfg, []string{archive}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "unfinished") {
		t.Fatalf("restore err=%v, want a refusal", err)
	}
	expectLive(t, cfg, "original")
	if info, err := os.Lstat(journal); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("journal entry changed: %v", err)
	}
}
