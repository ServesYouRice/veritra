package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolvePathsCanonicalizesSymlinksAndMissingTails(t *testing.T) {
	root := t.TempDir()
	real := filepath.Join(root, "real")
	if err := os.Mkdir(real, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	cfg, err := Config{
		DataDir:      link,
		DatabasePath: filepath.Join(link, "nested", "..", "private-messenger.db"),
		StoragePath:  filepath.Join(link, "blobs"),
	}.ResolvePaths()
	if err != nil {
		t.Fatal(err)
	}
	canonicalRoot, err := filepath.EvalSymlinks(real)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DataDir != canonicalRoot ||
		cfg.DatabasePath != filepath.Join(canonicalRoot, "private-messenger.db") ||
		cfg.StoragePath != filepath.Join(canonicalRoot, "blobs") {
		t.Fatalf("paths not canonical: %s %s %s", cfg.DataDir, cfg.DatabasePath, cfg.StoragePath)
	}
}

func TestResolvePathsRejectsOverlappingOwnership(t *testing.T) {
	root := t.TempDir()
	data := filepath.Join(root, "data")
	cases := map[string]Config{
		"blobs are data dir":       {DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: data},
		"blobs contain data dir":   {DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: root},
		"database in blobs":        {DataDir: data, DatabasePath: filepath.Join(root, "blobs", "db"), StoragePath: filepath.Join(root, "blobs")},
		"database is blobs":        {DataDir: data, DatabasePath: filepath.Join(root, "x"), StoragePath: filepath.Join(root, "x")},
		"database is data dir":     {DataDir: data, DatabasePath: data, StoragePath: filepath.Join(data, "blobs")},
		"database in backups":      {DataDir: data, DatabasePath: filepath.Join(data, "backups", "db"), StoragePath: filepath.Join(data, "blobs")},
		"blobs in backups":         {DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: filepath.Join(data, "backups", "blobs")},
		"blobs contain backups":    {DataDir: filepath.Join(data, "inner"), DatabasePath: filepath.Join(root, "db"), StoragePath: data},
		"relative blobs alias dir": {DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: filepath.Join(data, "blobs", "..")},
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := cfg.ResolvePaths(); err == nil {
				t.Fatal("overlapping layout accepted")
			}
		})
	}
}

func TestResolvePathsAcceptsSeparateOverrides(t *testing.T) {
	root := t.TempDir()
	cfg, err := Config{
		DataDir:      filepath.Join(root, "state"),
		DatabasePath: filepath.Join(root, "db", "private-messenger.db"),
		StoragePath:  filepath.Join(root, "blobs"),
	}.ResolvePaths()
	if err != nil {
		t.Fatal(err)
	}
	database, blobs := cfg.LockPaths()
	if !strings.HasSuffix(database, filepath.Join("db", "private-messenger.db.veritra-server.lock")) ||
		blobs != filepath.Join(cfg.StoragePath, ".veritra-server.lock") {
		t.Fatalf("lock paths: %s %s", database, blobs)
	}
}
