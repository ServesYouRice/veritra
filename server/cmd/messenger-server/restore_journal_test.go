package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A journal is trusted only when every path it names sits directly beside
// the live path it belongs to. A lexical prefix is not enough: a rollback path
// that climbs out with ".." through a directory carrying the prefix would let
// recovery move a foreign file onto the live database.
func TestJournalPathsMustStayBesideTheLiveInstance(t *testing.T) {
	cases := map[string]func(journal *restoreJournal, live, liveBlobs, victim string){
		"database rollback climbs out": func(j *restoreJournal, live, _, _ string) {
			j.DatabaseRollback = live + ".pre-restore-x/../../victim"
		},
		"database rollback inside a prefixed directory": func(j *restoreJournal, live, _, _ string) {
			j.DatabaseRollback = live + ".pre-restore-x/victim"
		},
		"database rollback with a trailing separator": func(j *restoreJournal, live, _, _ string) {
			j.DatabaseRollback = live + ".pre-restore-x" + string(filepath.Separator)
		},
		"database rollback outside the data directory": func(j *restoreJournal, _, _, victim string) {
			j.DatabaseRollback = victim
		},
		"companion rollback climbs out": func(j *restoreJournal, live, _, _ string) {
			j.Companions = map[string]string{live + "-wal": live + "-wal.pre-restore-x/../../victim"}
		},
		"blob rollback climbs out": func(j *restoreJournal, _, liveBlobs, _ string) {
			j.Blobs = liveBlobs
			j.BlobsRollback = liveBlobs + ".pre-restore-x/../../victim"
		},
		"staging directory with ..": func(j *restoreJournal, live, _, _ string) {
			j.StagingDir = filepath.Dir(live) + string(filepath.Separator) + "sub" + string(filepath.Separator) + ".." +
				string(filepath.Separator) + ".veritra-restore-x"
		},
	}
	for name, damage := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := seedInstance(t, "original")
			live, _ := filepath.Abs(cfg.DatabasePath)
			liveBlobs, _ := filepath.Abs(cfg.StoragePath)
			dir := filepath.Dir(live)
			// The prefixed directories exist, so the kernel resolves "..".
			for _, prefixed := range []string{live + ".pre-restore-x", live + "-wal.pre-restore-x", liveBlobs + ".pre-restore-x", filepath.Join(dir, "sub")} {
				if err := os.MkdirAll(prefixed, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			victim := filepath.Join(filepath.Dir(dir), "victim")
			if err := os.WriteFile(victim, []byte("operator data"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(live+".pre-restore-x", "victim"), []byte("operator data"), 0o600); err != nil {
				t.Fatal(err)
			}
			stage, err := makeStagingDir(dir, ".veritra-restore-")
			if err != nil {
				t.Fatal(err)
			}
			journal := restoreJournal{Version: 1, State: "activating", Database: live, StagingDir: stage}
			damage(&journal, live, liveBlobs, victim)
			if err := writeJournal(journalPath(live), journal); err != nil {
				t.Fatal(err)
			}
			err = recoverInterruptedRestore(cfg, &bytes.Buffer{})
			if err == nil || !strings.Contains(err.Error(), "does not match this instance") {
				t.Fatalf("recovery err=%v, want a journal mismatch", err)
			}
			for _, path := range []string{victim, filepath.Join(live+".pre-restore-x", "victim")} {
				if data, err := os.ReadFile(path); err != nil || string(data) != "operator data" {
					t.Fatalf("%s was moved or changed: %q %v", path, data, err)
				}
			}
			expectLive(t, cfg, "original")
			if _, err := os.Stat(journalPath(live)); err != nil {
				t.Fatalf("the untrusted journal was removed: %v", err)
			}
		})
	}
}

// A journal that a real restore wrote passes the containment checks.
func TestJournalWrittenByARealRestoreIsAccepted(t *testing.T) {
	for _, step := range []string{"restore:activate-database", "restore:activate-blobs", "restore:validate"} {
		t.Run(step, func(t *testing.T) {
			live, _ := crashRestoreAt(t, step)
			if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
				t.Fatalf("recovery rejected a genuine journal: %v", err)
			}
			expectLive(t, live, "original")
			expectNoStaging(t, live.DataDir)
		})
	}
}
