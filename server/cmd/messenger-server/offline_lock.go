package main

import (
	"errors"
	"fmt"
	"os"

	"private-messenger/server/internal/config"
)

// serverExclusion holds, for an offline command, the process locks that
// serve() holds for its whole life: the data-directory lock and the database
// lock. A running server keeps them when it is idle, which SQLite's own locks
// cannot show in WAL mode, so a command that must not run beside a server
// (restore, reset-owner-password) takes them without blocking and stops if it
// cannot. The blob-storage lock is left out on purpose: a restore swaps the
// blob directory, which holds that lock file. A server always holds all
// three, so the first two are enough to find one.
type serverExclusion struct {
	instance *instanceLock
	database *os.File
}

func acquireServerExclusion(cfg config.Config) (*serverExclusion, error) {
	instance, err := acquireInstanceLock(cfg.DataDir)
	if err != nil {
		return nil, err
	}
	databaseLockPath, _ := cfg.LockPaths()
	file, err := os.OpenFile(databaseLockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		_ = instance.Release()
		return nil, fmt.Errorf("open database process lock: %w", err)
	}
	if err := lockFileExclusive(file); err != nil {
		_ = file.Close()
		_ = instance.Release()
		return nil, fmt.Errorf("database lock %s is held by another process: %w", databaseLockPath, err)
	}
	return &serverExclusion{instance: instance, database: file}, nil
}

func (lock *serverExclusion) Release() error {
	if lock == nil {
		return nil
	}
	var errs []error
	if lock.database != nil {
		errs = append(errs, unlockFile(lock.database), lock.database.Close())
		lock.database = nil
	}
	errs = append(errs, lock.instance.Release())
	lock.instance = nil
	return errors.Join(errs...)
}
