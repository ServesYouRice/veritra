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

// DataDir/backups may be a symlink (for example to another disk), but it must
// not resolve onto or over live data (VAL-212).
func TestResolvePathsChecksResolvedBackupsDirectory(t *testing.T) {
	setup := func(t *testing.T) (root, data string) {
		t.Helper()
		root = t.TempDir()
		data = filepath.Join(root, "data")
		if err := os.MkdirAll(data, 0o700); err != nil {
			t.Fatal(err)
		}
		return root, data
	}
	link := func(t *testing.T, target, data string) {
		t.Helper()
		if err := os.MkdirAll(target, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, filepath.Join(data, "backups")); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
	}
	cases := map[string]struct {
		target func(root, data string) string
		cfg    func(root, data string) Config
		reject bool
	}{
		"backups link to blob directory": {
			target: func(root, data string) string { return filepath.Join(root, "blobs") },
			cfg: func(root, data string) Config {
				return Config{DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: filepath.Join(root, "blobs")}
			},
			reject: true,
		},
		"backups link to a directory containing the blobs": {
			target: func(root, data string) string { return filepath.Join(root, "shared") },
			cfg: func(root, data string) Config {
				return Config{DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: filepath.Join(root, "shared", "blobs")}
			},
			reject: true,
		},
		"backups link to the directory holding the database": {
			target: func(root, data string) string { return filepath.Join(root, "dbdir") },
			cfg: func(root, data string) Config {
				return Config{DataDir: data, DatabasePath: filepath.Join(root, "dbdir", "private-messenger.db"), StoragePath: filepath.Join(data, "blobs")}
			},
			reject: true,
		},
		"backups link inside the blob directory": {
			target: func(root, data string) string { return filepath.Join(root, "blobs", "backups") },
			cfg: func(root, data string) Config {
				return Config{DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: filepath.Join(root, "blobs")}
			},
			reject: true,
		},
		"backups link to an unrelated directory": {
			target: func(root, data string) string { return filepath.Join(root, "otherdisk", "backups") },
			cfg: func(root, data string) Config {
				return Config{DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: filepath.Join(root, "blobs")}
			},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			root, data := setup(t)
			link(t, tc.target(root, data), data)
			_, err := tc.cfg(root, data).ResolvePaths()
			if tc.reject && err == nil {
				t.Fatal("backups symlink onto live data was accepted")
			}
			if !tc.reject && err != nil {
				t.Fatalf("legitimate symlinked backups rejected: %v", err)
			}
		})
	}
	t.Run("plain backups directory", func(t *testing.T) {
		root, data := setup(t)
		if err := os.Mkdir(filepath.Join(data, "backups"), 0o700); err != nil {
			t.Fatal(err)
		}
		if _, err := (Config{DataDir: data, DatabasePath: filepath.Join(data, "db"), StoragePath: filepath.Join(root, "blobs")}).ResolvePaths(); err != nil {
			t.Fatalf("plain backups directory rejected: %v", err)
		}
	})
}
