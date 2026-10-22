package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"private-messenger/server/internal/config"
)

const instanceLockName = ".veritra-server.lock"

// instanceLock is an OS advisory lock (flock on unix, LockFileEx on Windows)
// held on the data directory's lock file for the process lifetime. The kernel
// drops it when the process exits for any reason, including SIGKILL, OOM kill
// or a crash, so a leftover lock file never blocks the next start. The file
// itself is kept: deleting it on release would let a new process lock a fresh
// inode while another still holds the unlinked one.
type instanceLock struct {
	file *os.File
}

func acquireInstanceLock(dataDir string) (*instanceLock, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data directory for process lock: %w", err)
	}
	path := filepath.Join(dataDir, instanceLockName)
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open server process lock: %w", err)
	}
	if err := lockFileExclusive(file); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("another server process holds the lock at %s; do not run multiple writers against one data directory: %w", path, err)
	}
	// The contents are diagnostic only; the advisory lock is the guard.
	if err := writeInstanceLockInfo(file); err != nil {
		_ = unlockFile(file)
		_ = file.Close()
		return nil, fmt.Errorf("write server process lock: %w", err)
	}
	return &instanceLock{file: file}, nil
}

func writeInstanceLockInfo(file *os.File) error {
	if err := file.Truncate(0); err != nil {
		return err
	}
	if _, err := file.WriteAt([]byte(fmt.Sprintf("pid=%d\nstarted_at=%s\n", os.Getpid(), time.Now().UTC().Format(time.RFC3339))), 0); err != nil {
		return err
	}
	return file.Sync()
}

func (lock *instanceLock) Release() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	unlockErr := unlockFile(lock.file)
	closeErr := lock.file.Close()
	lock.file = nil
	return errors.Join(unlockErr, closeErr)
}

// resourceLocks hold OS file locks on the canonical database and blob
// directory. The data-directory lock alone cannot see an overridden
// PRIVATE_MESSENGER_DB_PATH or PRIVATE_MESSENGER_STORAGE_PATH shared by two
// data directories; these locks can. The OS drops them when the process
// exits, so they never go stale after a crash.
type resourceLocks struct {
	files []*os.File
}

func acquireResourceLocks(cfg config.Config) (*resourceLocks, error) {
	databaseLock, blobLock := cfg.LockPaths()
	locks := &resourceLocks{}
	for _, item := range []struct{ name, path string }{
		{"database", databaseLock},
		{"blob storage", blobLock},
	} {
		if err := os.MkdirAll(filepath.Dir(item.path), 0o700); err != nil {
			_ = locks.Release()
			return nil, fmt.Errorf("create %s directory for process lock: %w", item.name, err)
		}
		file, err := os.OpenFile(item.path, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			_ = locks.Release()
			return nil, fmt.Errorf("open %s process lock: %w", item.name, err)
		}
		if err := lockFileExclusive(file); err != nil {
			_ = file.Close()
			_ = locks.Release()
			return nil, fmt.Errorf("%s lock %s is held by another server process; do not run multiple writers: %w", item.name, item.path, err)
		}
		locks.files = append(locks.files, file)
	}
	return locks, nil
}

func (locks *resourceLocks) Release() error {
	if locks == nil {
		return nil
	}
	var errs []error
	for _, file := range locks.files {
		errs = append(errs, unlockFile(file), file.Close())
	}
	locks.files = nil
	return errors.Join(errs...)
}
