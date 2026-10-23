package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"private-messenger/server/internal/backupstatus"
	"private-messenger/server/internal/config"
)

func TestScheduledBackupVerifiesCopiesAndPrunes(t *testing.T) {
	source := seedInstance(t, "live")
	offsite := t.TempDir()
	clock := time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC)
	options := scheduledBackupOptions{
		LocalDir: filepath.Join(source.DataDir, "backups"), OffsiteDir: offsite, Keep: 2,
		Now: func() time.Time { return clock },
	}
	// Things in the backup directories that are not scheduled backups.
	for _, dir := range []string{options.LocalDir, offsite} {
		if err := os.MkdirAll(filepath.Join(dir, "veritra-manual-copy"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(dir, "veritra-20200101T000000Z"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for day := 0; day < 3; day++ {
		clock = clock.Add(24 * time.Hour)
		if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
	}
	for _, dir := range []string{options.LocalDir, offsite} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		var names []string
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		want := []string{"veritra-20200101T000000Z", "veritra-20260926T000000Z", "veritra-20260927T000000Z", "veritra-manual-copy"}
		if len(names) != len(want) {
			t.Fatalf("%s holds %v, want %v", dir, names, want)
		}
		for i := range want {
			if names[i] != want[i] {
				t.Fatalf("%s holds %v, want %v", dir, names, want)
			}
		}
	}
	// The off-host copy restores on a clean host.
	if err := verifyBackup(context.Background(), config.Config{DataDir: t.TempDir()}, []string{filepath.Join(offsite, "veritra-20260927T000000Z")}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	status, ok := backupstatus.Read(source.DataDir)
	if !ok || status.LastSuccessAt == nil || !status.LastSuccessAt.Equal(clock) || status.ConsecutiveFailures != 0 {
		t.Fatalf("status=%#v", status)
	}
	expectNoStaging(t, offsite, options.LocalDir)
}

func TestScheduledBackupFailureIsRecordedWithoutSuccess(t *testing.T) {
	source := seedInstance(t, "live")
	offsite := t.TempDir()
	clock := time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC)
	options := scheduledBackupOptions{
		LocalDir: filepath.Join(source.DataDir, "backups"), OffsiteDir: offsite, Keep: 3,
		Now: func() time.Time { return clock },
	}
	withFault(t, "offsite:copy", &os.PathError{Op: "write", Path: "x", Err: syscall.ENOSPC})
	for attempt := 1; attempt <= 2; attempt++ {
		clock = clock.Add(time.Hour)
		if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err == nil {
			t.Fatal("scheduled backup succeeded despite the off-host failure")
		}
		status, ok := backupstatus.Read(source.DataDir)
		if !ok || status.LastSuccessAt != nil || status.LastFailureStep != backupstatus.StepOffsite || status.ConsecutiveFailures != attempt {
			t.Fatalf("status=%#v", status)
		}
	}
	if entries, _ := os.ReadDir(offsite); len(entries) != 0 {
		t.Fatalf("a partial off-host backup was published: %v", entries)
	}
	faultHook = func(string) error { return nil }
	clock = clock.Add(time.Hour)
	if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if status, _ := backupstatus.Read(source.DataDir); status.ConsecutiveFailures != 0 || status.LastFailureStep != "" {
		t.Fatalf("status after recovery=%#v", status)
	}
}

func TestScheduledBackupRecordsRestoreDrillOutcome(t *testing.T) {
	source := seedInstance(t, "live")
	clock := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	options := scheduledBackupOptions{
		LocalDir: filepath.Join(source.DataDir, "backups"), Keep: 3,
		Now: func() time.Time { return clock },
	}
	if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	status, _ := backupstatus.Read(source.DataDir)
	if status.LastDrillAt == nil || !status.LastDrillAt.Equal(clock) || !status.LastDrillPassed {
		t.Fatalf("passing drill not recorded: %#v", status)
	}
	withFault(t, "restore:stage-database", &os.PathError{Op: "write", Path: "x", Err: syscall.EIO})
	clock = clock.Add(time.Hour)
	if err := scheduledBackup(context.Background(), source, options, &bytes.Buffer{}); err == nil {
		t.Fatal("scheduled backup succeeded although its restore drill failed")
	}
	status, _ = backupstatus.Read(source.DataDir)
	if status.LastDrillAt == nil || !status.LastDrillAt.Equal(clock) || status.LastDrillPassed ||
		status.LastFailureStep != backupstatus.StepVerify || status.LastSuccessAt == nil || !status.LastSuccessAt.Equal(clock.Add(-time.Hour)) {
		t.Fatalf("failed drill not recorded: %#v", status)
	}
}

func TestStandaloneDrillRecordsOnlyForAnInstanceDataDir(t *testing.T) {
	scratch := commandConfig(t.TempDir())
	recordStandaloneDrill(scratch, true, time.Now(), &bytes.Buffer{})
	if _, ok := backupstatus.Read(scratch.DataDir); ok {
		t.Fatal("a drill in scratch space wrote a status file")
	}
	live := seedInstance(t, "live")
	at := time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)
	recordStandaloneDrill(live, false, at, &bytes.Buffer{})
	status, ok := backupstatus.Read(live.DataDir)
	if !ok || status.LastDrillAt == nil || !status.LastDrillAt.Equal(at) || status.LastDrillPassed {
		t.Fatalf("standalone drill result=%#v", status)
	}
}
