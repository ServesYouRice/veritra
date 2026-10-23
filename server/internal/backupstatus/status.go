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
	"time"
)

const fileName = "backup-status.json"

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

// RecordSuccess marks a backup that passed its restore drill.
func RecordSuccess(dataDir string, now time.Time) error {
	status, _ := Read(dataDir)
	now = now.UTC()
	status.LastAttemptAt = now
	status.LastSuccessAt = &now
	status.LastFailureStep = ""
	status.ConsecutiveFailures = 0
	return write(dataDir, status)
}

// RecordFailure marks a failed attempt at step.
func RecordFailure(dataDir, step string, now time.Time) error {
	status, _ := Read(dataDir)
	now = now.UTC()
	status.LastAttemptAt = now
	status.LastFailureAt = &now
	status.LastFailureStep = step
	status.ConsecutiveFailures++
	return write(dataDir, status)
}

// RecordDrill records the outcome of a restore drill and keeps every other
// field.
func RecordDrill(dataDir string, passed bool, now time.Time) error {
	status, _ := Read(dataDir)
	now = now.UTC()
	status.LastDrillAt = &now
	status.LastDrillPassed = passed
	return write(dataDir, status)
}

func write(dataDir string, status Status) error {
	if dataDir == "" {
		return errors.New("backup status needs a data directory")
	}
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	tmp := path(dataDir) + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path(dataDir))
}
