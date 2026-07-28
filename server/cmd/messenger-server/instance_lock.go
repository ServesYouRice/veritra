package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
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
