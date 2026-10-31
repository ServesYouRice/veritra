package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"syscall"
	"testing"
	"time"

	"private-messenger/server/internal/backupstatus"
)

// scheduledBackups lists the directories pruneBackups counts toward Keep.
func scheduledBackups(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || len(name) != len(backupNamePrefix)+len("20060102T150405Z") || name[:len(backupNamePrefix)] != backupNamePrefix {
			continue
		}
		if _, err := readAndValidateBackupManifest(filepath.Join(dir, name)); err == nil {
			names = append(names, name)
		}
	}
	return names
}

func backupName(at time.Time) string {
	return backupNamePrefix + at.UTC().Format("20060102T150405Z")
}

// The default local directory is on the live data volume: an off-host
// outage must not let local backups grow past Keep.
func TestScheduledBackupOffsiteFailureKeepsLocalRetention(t *testing.T) {
	source := seedInstance(t, "live")
	clock := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
	options := scheduledBackupOptions{
		LocalDir: filepath.Join(source.DataDir, "backups"), OffsiteDir: t.TempDir(), Keep: 2,
		Now: func() time.Time { return clock },
	}
	withFault(t, "offsite:copy", &os.PathError{Op: "write", Path: "x", Err: syscall.ENOSPC})
	for run := 1; run <= 4; run++ {
		clock = clock.Add(time.Hour)
		if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err == nil {
			t.Fatal("scheduled backup succeeded despite the off-host failure")
		}
		status, _ := backupstatus.Read(source.DataDir)
		if status.LastFailureStep != backupstatus.StepOffsite || status.ConsecutiveFailures != run || status.LastSuccessAt != nil {
			t.Fatalf("run %d status=%#v", run, status)
		}
	}
	local := scheduledBackups(t, options.LocalDir)
	if len(local) > options.Keep || !slices.Contains(local, backupName(clock)) {
		t.Fatalf("local backups after repeated off-host failures: %v (keep %d, newest %s)", local, options.Keep, backupName(clock))
	}
	if entries, _ := os.ReadDir(options.OffsiteDir); len(entries) != 0 {
		t.Fatalf("off-host directory changed: %v", entries)
	}
}

// A backup that failed its restore drill must not take the place of a
// verified one under Keep.
func TestScheduledBackupDrillFailureDoesNotCountTowardKeep(t *testing.T) {
	source := seedInstance(t, "live")
	clock := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
	options := scheduledBackupOptions{
		LocalDir: filepath.Join(source.DataDir, "backups"), Keep: 2,
		Now: func() time.Time { return clock },
	}
	var verified []string
	for range 2 {
		clock = clock.Add(time.Hour)
		if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
		verified = append(verified, backupName(clock))
	}
	clock = clock.Add(time.Hour)
	failed := backupName(clock)
	withFault(t, "restore:stage-database", &os.PathError{Op: "write", Path: "x", Err: syscall.EIO})
	if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err == nil {
		t.Fatal("scheduled backup succeeded although its restore drill failed")
	}
	faultHook = func(string) error { return nil }
	if status, _ := backupstatus.Read(source.DataDir); status.LastFailureStep != backupstatus.StepVerify || status.LastDrillPassed {
		t.Fatalf("status=%#v", status)
	}
	if local := scheduledBackups(t, options.LocalDir); !slices.Equal(local, verified) {
		t.Fatalf("local backups after a failed drill: %v, want the verified %v", local, verified)
	}
	if _, err := os.Lstat(filepath.Join(options.LocalDir, failed)); !os.IsNotExist(err) {
		t.Fatalf("the backup that failed its drill is still there: %v", err)
	}
	// The next good run prunes the oldest verified backup, not the failed one.
	clock = clock.Add(time.Hour)
	if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if local, want := scheduledBackups(t, options.LocalDir), []string{verified[1], backupName(clock)}; !slices.Equal(local, want) {
		t.Fatalf("local backups=%v want %v", local, want)
	}
}

// A run that cannot record its drill result still keeps LocalDir to Keep.
func TestScheduledBackupStatusFailureKeepsLocalRetention(t *testing.T) {
	source := seedInstance(t, "live")
	clock := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
	options := scheduledBackupOptions{
		LocalDir: filepath.Join(source.DataDir, "backups"), Keep: 1,
		Now: func() time.Time { return clock },
	}
	clock = clock.Add(time.Hour)
	if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	// The status file cannot be replaced.
	status := filepath.Join(source.DataDir, "backup-status.json")
	if err := os.Remove(status); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(status, "blocked"), 0o700); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(time.Hour)
	if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err == nil {
		t.Fatal("scheduled backup succeeded although its status could not be recorded")
	}
	if local, want := scheduledBackups(t, options.LocalDir), []string{backupName(clock)}; !slices.Equal(local, want) {
		t.Fatalf("local backups=%v want %v", local, want)
	}
}
