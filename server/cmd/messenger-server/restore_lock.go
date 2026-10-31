package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type restoreLock struct {
	file *os.File
}

func acquireRestoreLock(databasePath string) (*restoreLock, error) {
	return acquireLockFile(databasePath+".restore.lock", "another restore is active for this database")
}

// acquireRestoreDirLock locks the directory that holds the restore journal.
// The journal is one file per directory while the restore lock is per
// database, so two databases with one parent directory share a journal path:
// whoever acts on the journal holds this lock as well. The file sits beside
// the database, never inside the blob directory a restore renames (config
// validation keeps the database out of it), and it is never removed, since
// unlinking a locked file would let a second holder lock a new one.
func acquireRestoreDirLock(databasePath string) (*restoreLock, error) {
	return acquireLockFile(filepath.Join(filepath.Dir(databasePath), restoreDirLockName),
		"another restore is active in this directory")
}

func acquireLockFile(path, busy string) (*restoreLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open restore lock: %w", err)
	}
	if err := lockFileExclusive(file); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("%s: %w", busy, err)
	}
	return &restoreLock{file: file}, nil
}

func (lock *restoreLock) Release() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	unlockErr := unlockFile(lock.file)
	closeErr := lock.file.Close()
	lock.file = nil
	return errors.Join(unlockErr, closeErr)
}
