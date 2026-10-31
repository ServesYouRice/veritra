// Package backupstatus records the outcome of scheduled backups (card I45)
// so the server can report backup age without reading any backup.
//
// The status holds times, a step name and a count only: no paths,
// destinations, credentials or error text.
package backupstatus

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	fileName     = "backup-status.json"
	lockFileName = "backup-status.lock"
)

// Status is the last known state of scheduled backups.
//
// LastDrillAt and LastDrillPassed record the most recent restore drill:
// the one every scheduled backup runs, or `verify-backup` run against this
// data directory (for example on an off-host copy).
type Status struct {
	LastAttemptAt       time.Time  `json:"last_attempt_at"`
	LastSuccessAt       *time.Time `json:"last_success_at,omitempty"`
	LastFailureAt       *time.Time `json:"last_failure_at,omitempty"`
	LastFailureStep     string     `json:"last_failure_step,omitempty"`
	ConsecutiveFailures int        `json:"consecutive_failures"`
	LastDrillAt         *time.Time `json:"last_drill_at,omitempty"`
	LastDrillPassed     bool       `json:"last_drill_passed,omitempty"`
}

// Steps a scheduled backup can fail at.
const (
	StepBackup  = "backup"
	StepVerify  = "verify"
	StepOffsite = "offsite"
	StepPrune   = "prune"
)

func path(dataDir string) string { return filepath.Join(dataDir, fileName) }

// Read returns the recorded status, or false when none was recorded.
func Read(dataDir string) (Status, bool) {
	raw, err := os.ReadFile(path(dataDir))
	if err != nil || len(raw) > 4096 {
		return Status{}, false
	}
	var status Status
	if err := json.Unmarshal(raw, &status); err != nil {
		return Status{}, false
	}
	return status, true
}

// The recorders read, change and replace one small file. Scheduled backups
// and verify-backup may run against the same data directory at once, so each
// recorder holds an in-process mutex and an exclusive advisory lock on
// backup-status.lock for the whole read-modify-write. Read takes no lock: a
// replacement is an atomic rename, so it sees the old or the new file.
var recordMu sync.Mutex

// withLock runs fn with the status file locked against other recorders in
// this and other processes.
func withLock(dataDir string, fn func() error) error {
	if dataDir == "" {
		return errors.New("backup status needs a data directory")
	}
	recordMu.Lock()
	defer recordMu.Unlock()
	lock, err := os.OpenFile(filepath.Join(dataDir, lockFileName), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := lockFile(lock); err != nil {
		return err
	}
	defer func() { _ = unlockFile(lock) }()
	return fn()
}

// RecordSuccess marks a backup that passed its restore drill.
func RecordSuccess(dataDir string, now time.Time) error {
	return withLock(dataDir, func() error {
		status, _ := Read(dataDir)
		now = now.UTC()
		status.LastAttemptAt = now
		status.LastSuccessAt = &now
		status.LastFailureStep = ""
		status.ConsecutiveFailures = 0
		return write(dataDir, status)
	})
}

// RecordFailure marks a failed attempt at step.
func RecordFailure(dataDir, step string, now time.Time) error {
	return withLock(dataDir, func() error {
		status, _ := Read(dataDir)
		now = now.UTC()
		status.LastAttemptAt = now
		status.LastFailureAt = &now
		status.LastFailureStep = step
		status.ConsecutiveFailures++
		return write(dataDir, status)
	})
}

// RecordDrill records the outcome of a restore drill and keeps every other
// field.
func RecordDrill(dataDir string, passed bool, now time.Time) error {
	return withLock(dataDir, func() error {
		status, _ := Read(dataDir)
		now = now.UTC()
		status.LastDrillAt = &now
		status.LastDrillPassed = passed
		return write(dataDir, status)
	})
}

// write replaces the status file through a unique temporary file in the same
// directory: written, synced, renamed, and the directory synced. The caller
// holds the lock.
func write(dataDir string, status Status) (err error) {
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dataDir, "backup-status-*.tmp")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()
	if err = tmp.Chmod(0o600); err != nil {
		return err
	}
	if _, err = tmp.Write(data); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	if err = os.Rename(tmp.Name(), path(dataDir)); err != nil {
		return err
	}
	return syncDirectory(dataDir)
}
