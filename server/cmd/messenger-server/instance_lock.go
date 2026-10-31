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

// writerLocks are the locks serve holds for its whole life: the
// data-directory lock and the database and blob-storage locks. init and
// migrate take them too (I46), after any interrupted restore is settled.
type writerLocks struct {
	instance  *instanceLock
	resources *resourceLocks
}

// acquireWriterLocks takes the writer locks without blocking. It then
// refuses to go on if a restore journal is present: a restore killed after
// recovery ran but before these locks were taken leaves one, and the
// instance must be settled before anything opens it.
func acquireWriterLocks(cfg config.Config) (*writerLocks, error) {
	instance, err := acquireInstanceLock(cfg.DataDir)
	if err != nil {
		return nil, err
	}
	resources, err := acquireResourceLocks(cfg)
	if err != nil {
		_ = instance.Release()
		return nil, err
	}
	locks := &writerLocks{instance: instance, resources: resources}
	if err := requireSettledRestore(cfg); err != nil {
		_ = locks.Release()
		return nil, err
	}
	return locks, nil
}

func (locks *writerLocks) Release() error {
	if locks == nil {
		return nil
	}
	return errors.Join(locks.resources.Release(), locks.instance.Release())
}

// blobStorageLock is the blob-storage lock a server holds, taken by an
// offline command. Its file lives inside the blob directory, which restore
// and its rollback rename, so the command lets go before it moves that
// directory: Windows refuses to rename a directory with an open file inside,
// and on unix the lock would leave with the old directory anyway. A server
// started after that point locks a fresh file in the new directory; the
// data-directory and database locks still keep out a server of this
// instance, but not one of another database sharing the blob directory
// (bug-hunt Q-004: moving the lock file needs a config change).
type blobStorageLock struct {
	file *os.File
}

// lockExistingBlobStorage takes the blob-storage lock without blocking when
// the blob directory exists. A missing directory has no server using it, and
// is not created: a restore onto a clean host keeps its layout.
func lockExistingBlobStorage(cfg config.Config) (*blobStorageLock, error) {
	_, path := cfg.LockPaths()
	if _, err := os.Stat(cfg.StoragePath); os.IsNotExist(err) {
		return &blobStorageLock{}, nil
	} else if err != nil {
		return nil, fmt.Errorf("check blob storage for a process lock: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open blob storage process lock: %w", err)
	}
	if err := lockFileExclusive(file); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("blob storage lock %s is held by another server process; do not run multiple writers: %w", path, err)
	}
	return &blobStorageLock{file: file}, nil
}

func (lock *blobStorageLock) Release() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	unlockErr := unlockFile(lock.file)
	closeErr := lock.file.Close()
	lock.file = nil
	return errors.Join(unlockErr, closeErr)
}
