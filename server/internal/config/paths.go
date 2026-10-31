package config

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// ResolvePaths returns a copy whose data directory, database and blob paths
// are absolute and have every existing symlink resolved, so two spellings of
// one resource compare (and lock) as the same path. It then rejects layouts
// where one resource would sit inside another's ownership.
func (c Config) ResolvePaths() (Config, error) {
	var err error
	if c.DataDir, err = canonicalPath(c.DataDir); err != nil {
		return Config{}, fmt.Errorf("resolve data directory: %w", err)
	}
	if c.DatabasePath, err = canonicalPath(c.DatabasePath); err != nil {
		return Config{}, fmt.Errorf("resolve database path: %w", err)
	}
	if c.StoragePath, err = canonicalPath(c.StoragePath); err != nil {
		return Config{}, fmt.Errorf("resolve blob storage path: %w", err)
	}
	if err := c.validateOwnership(); err != nil {
		return Config{}, err
	}
	return c, nil
}

// validateOwnership expects canonical paths. The data directory owns the
// process lock, backups and status files; the blob directory is owned by the
// blob store alone; the database (and its -wal/-shm siblings) by SQLite.
func (c Config) validateOwnership() error {
	switch {
	case c.DatabasePath == c.DataDir:
		return errors.New("database path must be a file, not the data directory")
	case c.StoragePath == c.DataDir:
		return errors.New("blob storage path must not be the data directory itself")
	case c.StoragePath == c.DatabasePath:
		return errors.New("database and blob storage paths must differ")
	case within(c.DataDir, c.StoragePath):
		return errors.New("blob storage path must not contain the data directory")
	case within(c.DatabasePath, c.StoragePath):
		return errors.New("database must not be inside the blob storage directory")
	case within(c.StoragePath, c.DatabasePath):
		return errors.New("blob storage directory must not be inside the database path")
	}
	// The backups directory may itself be a symlink (to another disk, say),
	// so every overlap check runs against where it is spelled and where it
	// resolves to.
	backupsDir := filepath.Join(c.DataDir, "backups")
	for _, backups := range backupsLocations(backupsDir) {
		switch {
		case c.DatabasePath == backups || within(c.DatabasePath, backups):
			return errors.New("database must not be inside the data directory's backups directory")
		case c.StoragePath == backups || within(c.StoragePath, backups) || within(backups, c.StoragePath):
			return errors.New("blob storage must not overlap the data directory's backups directory")
		}
	}
	return nil
}

// backupsLocations returns the backups directory as spelled and, when it
// exists and resolves elsewhere (a symlink), where it really is.
func backupsLocations(backups string) []string {
	locations := []string{backups}
	if _, err := os.Lstat(backups); err != nil {
		return locations
	}
	if resolved, err := filepath.EvalSymlinks(backups); err == nil && resolved != backups {
		locations = append(locations, resolved)
	}
	return locations
}

// within reports whether path is strictly below dir.
func within(path, dir string) bool {
	rel, err := filepath.Rel(dir, path)
	if err != nil || rel == "." {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

// canonicalPath makes path absolute and resolves symlinks in its longest
// existing prefix. The remainder (not created yet) is appended unchanged.
func canonicalPath(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", errors.New("path is empty")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	existing := abs
	var rest []string
	for {
		resolved, err := filepath.EvalSymlinks(existing)
		if err == nil {
			parts := append([]string{resolved}, rest...)
			return filepath.Join(parts...), nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return abs, nil
		}
		rest = append([]string{filepath.Base(existing)}, rest...)
		existing = parent
	}
}

// LockPaths returns the lock files that give one server exclusive ownership
// of the canonical database and blob directory, wherever they live. The
// database lock sits beside the database (as the restore lock does); the
// blob lock is a dot-file the blob store never treats as a blob.
func (c Config) LockPaths() (database, blobs string) {
	return c.DatabasePath + ".veritra-server.lock", filepath.Join(c.StoragePath, ".veritra-server.lock")
}
