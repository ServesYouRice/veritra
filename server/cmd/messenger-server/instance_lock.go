package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"private-messenger/server/internal/config"
)

type instanceLock struct {
	file *os.File
	path string
}

func acquireInstanceLock(dataDir string) (*instanceLock, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data directory for process lock: %w", err)
	}
	path := filepath.Join(dataDir, ".veritra-server.lock")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return nil, fmt.Errorf("data directory already has a server process lock at %s; do not run multiple writers (after a hard crash, verify no server is running before removing the stale lock)", path)
	}
	if err != nil {
		return nil, fmt.Errorf("acquire server process lock: %w", err)
	}
	if _, err := fmt.Fprintf(file, "pid=%d\nstarted_at=%s\n", os.Getpid(), time.Now().UTC().Format(time.RFC3339)); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return nil, fmt.Errorf("write server process lock: %w", err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return nil, fmt.Errorf("sync server process lock: %w", err)
	}
	return &instanceLock{file: file, path: path}, nil
}

func (lock *instanceLock) Release() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	closeErr := lock.file.Close()
	removeErr := os.Remove(lock.path)
	lock.file = nil
	if removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
		return errors.Join(closeErr, removeErr)
	}
	return closeErr
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
