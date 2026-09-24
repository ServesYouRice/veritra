package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
)

// seedInstance creates a migrated instance whose database and one encrypted
// blob both carry label, so a test can tell which instance is live.
func seedInstance(t *testing.T, label string) config.Config {
	t.Helper()
	cfg := commandConfig(t.TempDir())
	if err := migrate(context.Background(), cfg, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(cfg.StoragePath, 0o700); err != nil {
		t.Fatal(err)
	}
	blob := []byte("ciphertext-" + label)
	sum := sha256.Sum256(blob)
	if err := os.WriteFile(filepath.Join(cfg.StoragePath, "blob_1"), blob, 0o600); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, statement := range []string{
		`CREATE TABLE IF NOT EXISTS drill_marker(value TEXT NOT NULL)`,
		`DELETE FROM drill_marker`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO drill_marker(value) VALUES(?)`, label); err != nil {
		t.Fatal(err)
	}
	store, err := storage.Open(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveOwnerEnrollment(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	owner, err := store.CreateOwner(context.Background(), storage.CreateOwnerInput{
		EnrollmentReservationID: reservation.ID, InstanceName: "drill", Username: "owner",
		PasswordHash: "x", DeviceName: "phone", KeyPackage: []byte("kp"), SigningKey: bytes.Repeat([]byte{1}, 32),
	})
	store.Close()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO attachment_envelopes(id, owner_account_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at)
		VALUES('att_1', ?, 'blob_1', ?, ?, '{}', '2026-09-24T00:00:00Z')`, owner.Account.ID, hex.EncodeToString(sum[:]), len(blob)); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func liveLabel(t *testing.T, cfg config.Config) (string, string) {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+cfg.DatabasePath+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var label string
	if err := db.QueryRow(`SELECT value FROM drill_marker`).Scan(&label); err != nil {
		t.Fatalf("read live database: %v", err)
	}
	blob, err := os.ReadFile(filepath.Join(cfg.StoragePath, "blob_1"))
	if err != nil {
		t.Fatalf("read live blob: %v", err)
	}
	return label, strings.TrimPrefix(string(blob), "ciphertext-")
}

func expectLive(t *testing.T, cfg config.Config, label string) {
	t.Helper()
	database, blob := liveLabel(t, cfg)
	if database != label || blob != label {
		t.Fatalf("live instance database=%q blob=%q want %q", database, blob, label)
	}
}

func expectNoStaging(t *testing.T, dirs ...string) {
	t.Helper()
	for _, dir := range dirs {
		entries, _ := os.ReadDir(dir)
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), ".veritra-") && entry.Name() != restoreJournalName {
				t.Fatalf("staging left behind: %s", filepath.Join(dir, entry.Name()))
			}
			if entry.Name() == restoreJournalName {
				t.Fatalf("restore journal left behind in %s", dir)
			}
		}
	}
}

func withFault(t *testing.T, step string, err error) {
	t.Helper()
	previous := faultHook
	faultHook = func(current string) error {
		if current == step {
			return err
		}
		return nil
	}
	t.Cleanup(func() { faultHook = previous })
}

func makeBackup(t *testing.T, cfg config.Config) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), "backup")
	if err := backup(context.Background(), cfg, []string{out}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestRestoreSurvivesFailureAndCrashAtEveryStep(t *testing.T) {
	steps := []string{
		"restore:stage-database", "restore:stage-blob", "restore:preserve-database",
		"restore:preserve-blobs", "restore:activate-database", "restore:activate-blobs",
		"restore:validate",
	}
	diskFull := &os.PathError{Op: "write", Path: "x", Err: syscall.ENOSPC}
	permission := &os.PathError{Op: "rename", Path: "x", Err: syscall.EACCES}
	for _, step := range steps {
		for name, fault := range map[string]error{"disk full": diskFull, "permission": permission, "crash": errSimulatedCrash} {
			t.Run(step+"/"+name, func(t *testing.T) {
				source := seedInstance(t, "backup")
				archive := makeBackup(t, source)
				live := seedInstance(t, "original")
				withFault(t, step, fault)
				err := restore(live, []string{archive}, &bytes.Buffer{})
				if !errors.Is(err, fault) {
					t.Fatalf("restore err=%v want %v", err, fault)
				}
				faultHook = func(string) error { return nil }
				// The next command settles a crash; a plain failure already
				// rolled back.
				var output bytes.Buffer
				if err := recoverInterruptedRestore(live, &output); err != nil {
					t.Fatal(err)
				}
				expectLive(t, live, "original")
				expectNoStaging(t, live.DataDir)
				// The instance still works and can be restored for real.
				if err := restore(live, []string{archive}, &bytes.Buffer{}); err != nil {
					t.Fatal(err)
				}
				expectLive(t, live, "backup")
			})
		}
	}
}

func TestRestoreCrashAfterActivationKeepsTheRestoredInstance(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	live := seedInstance(t, "original")
	withFault(t, "restore:finish", errSimulatedCrash)
	if err := restore(live, []string{archive}, &bytes.Buffer{}); !errors.Is(err, errSimulatedCrash) {
		t.Fatalf("err=%v", err)
	}
	faultHook = func(string) error { return nil }
	var output bytes.Buffer
	if err := run([]string{"doctor", "-data-dir", live.DataDir}, &output, &output); err != nil && !strings.Contains(err.Error(), "") {
		t.Fatal(err)
	}
	expectLive(t, live, "backup")
	expectNoStaging(t, live.DataDir)
	if !strings.Contains(output.String(), "had finished") {
		t.Fatalf("output=%q", output.String())
	}
}

func TestInterruptedRestoreRollsBackTheWALWithItsDatabase(t *testing.T) {
	live := seedInstance(t, "original")
	database, _ := filepath.Abs(live.DatabasePath)
	stage, err := makeStagingDir(filepath.Dir(database), ".veritra-restore-")
	if err != nil {
		t.Fatal(err)
	}
	suffix := ".pre-restore-20260924T000000Z-abc"
	// A crash after the database and its WAL were moved aside and the
	// restored copy put in place.
	for _, move := range [][2]string{{database, database + suffix}} {
		if err := os.Rename(move[0], move[1]); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(database+"-wal"+suffix, []byte("committed frames"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(database, []byte("restored copy"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeJournal(journalPath(database), restoreJournal{
		Version: 1, State: "activating", Database: database, DatabaseRollback: database + suffix,
		Companions: map[string]string{database + "-wal": database + "-wal" + suffix}, StagingDir: stage,
	}); err != nil {
		t.Fatal(err)
	}
	if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(database + "-wal"); err != nil || string(data) != "committed frames" {
		t.Fatalf("WAL not restored: %q %v", data, err)
	}
	_ = os.Remove(database + "-wal")
	expectLive(t, live, "original")
	expectNoStaging(t, live.DataDir)
}

func TestADamagedOrForeignJournalStopsStartup(t *testing.T) {
	live := seedInstance(t, "original")
	database, _ := filepath.Abs(live.DatabasePath)
	for name, journal := range map[string]string{
		"damaged": "{",
		"foreign": `{"version":1,"state":"activating","database":"` + database + `","database_rollback":"/etc/passwd","staging_dir":"/tmp/x"}`,
	} {
		t.Run(name, func(t *testing.T) {
			if err := os.WriteFile(journalPath(database), []byte(journal), 0o600); err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			if err := run([]string{"migrate", "-data-dir", live.DataDir}, &output, &output); err == nil {
				t.Fatal("startup ignored a journal it cannot trust")
			}
			expectLive(t, live, "original")
			_ = os.Remove(journalPath(database))
		})
	}
}

func TestRestoreRejectsCorruptOrIncompleteBackups(t *testing.T) {
	for name, damage := range map[string]func(string){
		"corrupt blob":   func(dir string) { _ = os.WriteFile(filepath.Join(dir, "blobs", "blob_1"), []byte("tampered"), 0o600) },
		"missing blob":   func(dir string) { _ = os.Remove(filepath.Join(dir, "blobs", "blob_1")) },
		"corrupt db":     func(dir string) { _ = os.WriteFile(filepath.Join(dir, "database.db"), []byte("not sqlite"), 0o600) },
		"bad manifest":   func(dir string) { _ = os.WriteFile(filepath.Join(dir, "manifest.json"), []byte("{"), 0o600) },
		"escaping blob":  func(dir string) { rewriteManifest(t, dir, `"storage_key": "blob_1"`, `"storage_key": "../blob_1"`) },
		"truncated file": func(dir string) { _ = os.Truncate(filepath.Join(dir, "database.db"), 100) },
	} {
		t.Run(name, func(t *testing.T) {
			archive := makeBackup(t, seedInstance(t, "backup"))
			damage(archive)
			live := seedInstance(t, "original")
			if err := restore(live, []string{archive}, &bytes.Buffer{}); err == nil {
				t.Fatal("damaged backup was restored")
			}
			expectLive(t, live, "original")
			expectNoStaging(t, live.DataDir)
			if err := verifyBackup(context.Background(), []string{archive}, &bytes.Buffer{}); err == nil {
				t.Fatal("damaged backup passed the restore drill")
			}
		})
	}
}

func rewriteManifest(t *testing.T, dir, old, replacement string) {
	t.Helper()
	path := filepath.Join(dir, "manifest.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(raw, []byte(old)) {
		t.Fatalf("manifest lacks %s: %s", old, raw)
	}
	if err := os.WriteFile(path, bytes.Replace(raw, []byte(old), []byte(replacement), 1), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestBackupAndRestoreLeaveForeignPathsAlone(t *testing.T) {
	source := seedInstance(t, "backup")
	out := filepath.Join(t.TempDir(), "backup")
	// Paths the old implementation reused and deleted.
	for _, dir := range []string{out + ".tmp", source.StoragePath + ".restore-tmp"} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "keep"), []byte("operator data"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := backup(context.Background(), source, []string{out}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	live := seedInstance(t, "original")
	foreign := live.StoragePath + ".restore-tmp"
	if err := os.MkdirAll(foreign, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(foreign, "keep"), []byte("operator data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := restore(live, []string{out}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{filepath.Join(out+".tmp", "keep"), filepath.Join(source.StoragePath+".restore-tmp", "keep"), filepath.Join(foreign, "keep")} {
		if data, err := os.ReadFile(path); err != nil || string(data) != "operator data" {
			t.Fatalf("%s was touched: %v", path, err)
		}
	}
	// A staging directory without the marker is never removed.
	unmarked := filepath.Join(t.TempDir(), ".veritra-restore-unmarked")
	if err := os.MkdirAll(unmarked, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := removeStagingDir(unmarked); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(unmarked); err != nil {
		t.Fatal("an unmarked directory was removed")
	}
}

func TestConcurrentBackupsDoNotCollide(t *testing.T) {
	source := seedInstance(t, "backup")
	parent := t.TempDir()
	var wg sync.WaitGroup
	errs := make([]error, 6)
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			out := filepath.Join(parent, "shared")
			if i%2 == 1 {
				out = filepath.Join(parent, "own-"+string(rune('a'+i)))
			}
			errs[i] = backup(context.Background(), source, []string{out}, &bytes.Buffer{})
		}(i)
	}
	wg.Wait()
	shared := 0
	for i, err := range errs {
		if i%2 == 1 && err != nil {
			t.Fatalf("own backup %d failed: %v", i, err)
		}
		if i%2 == 0 && err == nil {
			shared++
		}
	}
	if shared != 1 {
		t.Fatalf("%d backups claimed the shared destination", shared)
	}
	expectNoStaging(t, parent)
	for _, name := range []string{"shared", "own-b", "own-d", "own-f"} {
		if err := verifyBackup(context.Background(), []string{filepath.Join(parent, name)}, &bytes.Buffer{}); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
}

func TestBackupFailuresLeaveNoPartialBackup(t *testing.T) {
	for _, step := range []string{"backup:database", "backup:blob", "backup:publish"} {
		t.Run(step, func(t *testing.T) {
			source := seedInstance(t, "backup")
			parent := t.TempDir()
			out := filepath.Join(parent, "backup")
			withFault(t, step, &os.PathError{Op: "write", Path: "x", Err: syscall.ENOSPC})
			if err := backup(context.Background(), source, []string{out}, &bytes.Buffer{}); err == nil {
				t.Fatal("backup succeeded")
			}
			if _, err := os.Stat(out); !os.IsNotExist(err) {
				t.Fatal("a partial backup was published")
			}
			expectNoStaging(t, parent)
		})
	}
}

func TestASecondRestoreOrRecoveryWaitsForTheRunningRestore(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	live := seedInstance(t, "original")
	entered := make(chan struct{})
	release := make(chan struct{})
	previous := faultHook
	faultHook = func(step string) error {
		if step == "restore:preserve-database" {
			close(entered)
			<-release
		}
		return nil
	}
	t.Cleanup(func() { faultHook = previous })
	first := make(chan error, 1)
	go func() { first <- restore(live, []string{archive}, &bytes.Buffer{}) }()
	<-entered
	// The journal is on disk now; neither a second restore nor recovery may
	// touch it while the first restore holds the lock.
	if err := restore(live, []string{archive}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "another restore is active") {
		t.Fatalf("second restore err=%v", err)
	}
	if err := recoverInterruptedRestore(live, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "another restore is active") {
		t.Fatalf("recovery err=%v", err)
	}
	close(release)
	if err := <-first; err != nil {
		t.Fatalf("first restore: %v", err)
	}
	expectLive(t, live, "backup")
	expectNoStaging(t, live.DataDir)
}
