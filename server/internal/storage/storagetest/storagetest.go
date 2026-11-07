// Package storagetest provides a database that is already at the current
// schema, for tests outside the storage package. Nothing here is used by the
// server.
package storagetest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
	"private-messenger/server/migrations"
)

// Applying every migration costs about 0.2 s, but about 2 s under -race (CI
// runs `go test -race ./...`), and the httpapi tests build a fresh app for
// nearly every test. Setup alone took most of the 10-minute `go test`
// timeout of that package.
//
// SeedMigrated writes a database that was migrated once per test process with
// the real Open and Migrate(migrations.FS). The caller still starts the app or
// store on it, and Migrate then checks every applied checksum against the
// embedded files, exactly as a restart does. A test that exercises migration
// itself must not use it.
//
// All copies share the template's random values (the sync epoch and the
// recovery decoy key); no test compares them between two instances.
var (
	templateOnce  sync.Once
	templateBytes []byte
	templateErr   error
)

// SeedMigrated writes a fully migrated, empty database to path.
func SeedMigrated(tb testing.TB, path string) {
	tb.Helper()
	templateOnce.Do(func() { templateBytes, templateErr = buildTemplate() })
	if templateErr != nil {
		tb.Fatalf("migrated database template: %v", templateErr)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(path, templateBytes, 0o600); err != nil {
		tb.Fatal(err)
	}
}

func buildTemplate() ([]byte, error) {
	ctx := context.Background()
	dir, err := os.MkdirTemp("", "veritra-migrated-template-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "template.db")
	store, err := storage.Open(ctx, config.Config{Addr: ":0", DataDir: dir, DatabasePath: path, StoragePath: filepath.Join(dir, "blobs")})
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		_ = store.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	if err := store.Close(); err != nil {
		return nil, fmt.Errorf("close: %w", err)
	}
	// A clean close checkpoints the WAL into the main file. Copying only the
	// main file is correct only if nothing is left behind.
	if info, err := os.Stat(path + "-wal"); err == nil && info.Size() > 0 {
		return nil, fmt.Errorf("WAL not empty after close (%d bytes)", info.Size())
	}
	return os.ReadFile(path)
}
