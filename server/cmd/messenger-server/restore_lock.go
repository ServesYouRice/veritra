package main

import (
	"errors"
	"fmt"
	"os"
)

type restoreLock struct {
	file *os.File
}

func acquireRestoreLock(databasePath string) (*restoreLock, error) {
	file, err := os.OpenFile(databasePath+".restore.lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open restore lock: %w", err)
	}
	if err := lockFileExclusive(file); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("another restore is active for this database: %w", err)
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
