package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

// runFor runs a command against cfg's paths through run(), as an operator
// would.
func runFor(cfg config.Config, command string, rest ...string) error {
	args := append([]string{command, "-data-dir", cfg.DataDir, "-db", cfg.DatabasePath, "-storage", cfg.StoragePath}, rest...)
	var output bytes.Buffer
	return run(args, &output, &output)
}

func fileDigest(t *testing.T, path string) string {
	t.Helper()
	sum, _, err := fileSHA256(path)
	if err != nil {
		t.Fatal(err)
	}
	return sum
}

func expectNoRollbackCopies(t *testing.T, dirs ...string) {
	t.Helper()
	for _, dir := range dirs {
		entries, _ := os.ReadDir(dir)
		for _, entry := range entries {
			if strings.Contains(entry.Name(), ".pre-restore-") {
				t.Fatalf("restore moved live files: %s", filepath.Join(dir, entry.Name()))
			}
		}
	}
}

// writerCommands are the commands that write the live instance; each must
// stop while a server holds the instance's locks.
func writerCommands(t *testing.T, archive string) map[string][]string {
	t.Helper()
	return map[string][]string{
		"migrate":              nil,
		"init":                 nil,
		"reset-owner-password": {"-account", "owner", "-password-file", writePasswordFile(t)},
		"restore":              {archive},
	}
}

func TestWriterCommandsStopWhileTheDataDirectoryIsLocked(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	for command, rest := range writerCommands(t, archive) {
		t.Run(command+"/existing instance", func(t *testing.T) {
			live := seedInstance(t, "live")
			before := fileDigest(t, live.DatabasePath)
			server, err := acquireInstanceLock(live.DataDir)
			if err != nil {
				t.Fatal(err)
			}
			defer server.Release()
			if err := runFor(live, command, rest...); err == nil {
				t.Fatalf("%s ran beside a server", command)
			}
			if after := fileDigest(t, live.DatabasePath); after != before {
				t.Fatalf("%s changed the database beside a server", command)
			}
			expectLive(t, live, "live")
			expectNoRollbackCopies(t, live.DataDir)
		})
	}
	for _, command := range []string{"migrate", "init"} {
		t.Run(command+"/new instance", func(t *testing.T) {
			cfg := commandConfig(t.TempDir())
			server, err := acquireInstanceLock(cfg.DataDir)
			if err != nil {
				t.Fatal(err)
			}
			defer server.Release()
			err = runFor(cfg, command)
			if err == nil || !strings.Contains(err.Error(), "multiple writers") {
				t.Fatalf("%s beside a server: err=%v, want the data-directory lock error", command, err)
			}
			if _, err := os.Stat(cfg.DatabasePath); !os.IsNotExist(err) {
				t.Fatalf("%s created a database beside a server: %v", command, err)
			}
		})
	}
}

// A server on another database that shares the blob directory holds only the
// blob-storage lock; restore must not swap that directory under it.
func TestWriterCommandsStopWhileAServerSharesTheBlobDirectory(t *testing.T) {
	archive := makeBackup(t, seedInstance(t, "backup"))
	live := seedInstance(t, "live")
	other := commandConfig(t.TempDir())
	other.StoragePath = live.StoragePath
	resources, err := acquireResourceLocks(other)
	if err != nil {
		t.Fatal(err)
	}
	defer resources.Release()
	before := fileDigest(t, live.DatabasePath)
	for command, rest := range writerCommands(t, archive) {
		t.Run(command, func(t *testing.T) {
			err := runFor(live, command, rest...)
			if err == nil || !strings.Contains(err.Error(), "blob storage lock") {
				t.Fatalf("%s beside a server sharing the blobs: err=%v, want the blob-storage lock error", command, err)
			}
			if after := fileDigest(t, live.DatabasePath); after != before {
				t.Fatalf("%s changed the database", command)
			}
			expectLive(t, live, "live")
			expectNoRollbackCopies(t, live.DataDir)
		})
	}
}

func TestOnlineCommandsRunBesideAServer(t *testing.T) {
	live := seedInstance(t, "live")
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
	archive := filepath.Join(t.TempDir(), "backup")
	if err := runFor(live, "backup", archive); err != nil {
		t.Fatalf("backup beside a server: %v", err)
	}
	if err := runFor(live, "verify-backup", archive); err != nil {
		t.Fatalf("verify-backup beside a server: %v", err)
	}
	if err := runFor(live, "doctor"); err != nil {
		t.Fatalf("doctor beside a server: %v", err)
	}
	if err := runFor(live, "scheduled-backup"); err != nil {
		t.Fatalf("scheduled-backup beside a server: %v", err)
	}
}

// Settling an interrupted restore moves live files, so it waits for the
// server to stop rather than rolling back under it.
func TestRecoveryWaitsForTheServerToStop(t *testing.T) {
	live, journal := crashRestoreAt(t, "restore:validate")
	server, err := acquireInstanceLock(live.DataDir)
	if err != nil {
		t.Fatal(err)
	}
	err = runFor(live, "migrate")
	if err == nil || !strings.Contains(err.Error(), "stop") {
		t.Fatalf("recovery beside a server: err=%v", err)
	}
	if _, err := os.Stat(journal); err != nil {
		t.Fatalf("journal settled beside a server: %v", err)
	}
	expectLive(t, live, "backup")
	server.Release()
	if err := runFor(live, "migrate"); err != nil {
		t.Fatal(err)
	}
	expectLive(t, live, "original")
	expectNoStaging(t, live.DataDir)
}

// A restore killed between recovery and the command's own locks leaves a
// journal; the writer must not open the half-restored instance.
func TestWritersStopOnAJournalThatAppearsAfterRecovery(t *testing.T) {
	live, journal := crashRestoreAt(t, "restore:validate")
	locks, err := acquireWriterLocks(live)
	if err == nil {
		locks.Release()
		t.Fatal("writer locks taken with an unsettled restore journal")
	}
	if !strings.Contains(err.Error(), "interrupted restore") {
		t.Fatalf("err=%v", err)
	}
	if _, err := os.Stat(journal); err != nil {
		t.Fatal(err)
	}
	if err := resetOwnerPassword(t.Context(), live, "owner", writePasswordFile(t), &bytes.Buffer{}); err == nil ||
		!strings.Contains(err.Error(), "interrupted restore") {
		t.Fatalf("reset-owner-password with an unsettled journal: err=%v", err)
	}
	if again, err := acquireInstanceLock(live.DataDir); err != nil {
		t.Fatalf("a refused writer kept its lock: %v", err)
	} else {
		again.Release()
	}
}
