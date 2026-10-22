package main

// Canonical resource locks (card I46). The data-directory lock alone does not
// stop two servers whose PRIVATE_MESSENGER_DB_PATH or
// PRIVATE_MESSENGER_STORAGE_PATH overrides (or symlinks) point at the same
// database or blob directory. serve therefore also takes an advisory lock
// beside the canonical database file and the canonical blob directory. The
// operating system drops these locks when the process exits, so a crash
// leaves nothing stale behind.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"private-messenger/server/internal/config"
)

const resourceLockSuffix = ".veritra-serve.lock"

type resourceLocks struct {
	files []*os.File
}

// canonicalPath resolves p to an absolute path with every symlink in its
// existing prefix evaluated, so two spellings of one location compare equal
// even before the final component exists.
func canonicalPath(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	existing, rest := abs, ""
	for {
		resolved, err := filepath.EvalSymlinks(existing)
		if err == nil {
			return filepath.Join(resolved, rest), nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return abs, nil
		}
		rest = filepath.Join(filepath.Base(existing), rest)
		existing = parent
	}
}

func pathWithin(child, parent string) bool {
	rel, err := filepath.Rel(parent, child)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// checkResourceLayout rejects layouts in which the blob store would own the
// database or the data directory.
func checkResourceLayout(dataDir, database, blobs string) error {
	if pathWithin(database, blobs) {
		return errors.New("the database path must not be inside the blob storage directory")
	}
	if pathWithin(dataDir, blobs) {
		return errors.New("the blob storage directory must not be the data directory or contain it")
	}
	return nil
}

func acquireResourceLocks(cfg config.Config) (*resourceLocks, error) {
	dataDir, err := canonicalPath(cfg.DataDir)
	if err != nil {
		return nil, fmt.Errorf("resolve data directory: %w", err)
	}
	database, err := canonicalPath(cfg.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("resolve database path: %w", err)
	}
	blobs, err := canonicalPath(cfg.StoragePath)
	if err != nil {
		return nil, fmt.Errorf("resolve blob storage path: %w", err)
	}
	if err := checkResourceLayout(dataDir, database, blobs); err != nil {
		return nil, err
	}
	locks := &resourceLocks{}
	for _, target := range []struct{ name, path string }{
		{"database", database},
		{"blob storage", blobs},
	} {
		if err := os.MkdirAll(filepath.Dir(target.path), 0o700); err != nil {
			_ = locks.Release()
			return nil, fmt.Errorf("create %s parent directory: %w", target.name, err)
		}
		lockPath := target.path + resourceLockSuffix
		file, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			_ = locks.Release()
			return nil, fmt.Errorf("open %s lock: %w", target.name, err)
		}
		if err := lockFileExclusive(file); err != nil {
			_ = file.Close()
			_ = locks.Release()
			return nil, fmt.Errorf("another server already uses this %s (%s); do not run multiple writers", target.name, target.path)
		}
		locks.files = append(locks.files, file)
	}
	return locks, nil
}

func (locks *resourceLocks) Release() error {
	if locks == nil {
		return nil
	}
	var result error
	for _, file := range locks.files {
		result = errors.Join(result, unlockFile(file), file.Close())
	}
	locks.files = nil
	return result
}
