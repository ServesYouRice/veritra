package storage

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"private-messenger/server/internal/config"
	"private-messenger/server/migrations"
)

// Most tests need a store at the current schema and do not care how it got
// there. Applying every migration costs about 60 ms, but about 1.4 s under
// -race (CI runs `go test -race ./...`), and the package creates a store for
// nearly every test, so setup alone was a large share of the 10-minute
// `go test` timeout.
//
// seedMigratedDatabase writes a database that was migrated once per test
// process with the real Open and Migrate(migrations.FS). Callers still run
// Migrate on it, which verifies every applied checksum against the embedded
// files, so a helper keeps its contract. Tests that exercise migration itself
// (upgrades from old schemas, edited or broken migrations, checksum
// back-fill) do not use it and still start from an empty file.
//
// All copies share the template's randomly generated sync epoch; no test in
// this package compares epochs between stores.
var (
	migratedTemplateOnce  sync.Once
	migratedTemplateBytes []byte
	migratedTemplateErr   error
)

func seedMigratedDatabase(tb testing.TB, path string) {
	tb.Helper()
	migratedTemplateOnce.Do(func() {
		migratedTemplateBytes, migratedTemplateErr = buildMigratedTemplate()
	})
	if migratedTemplateErr != nil {
		tb.Fatalf("migrated database template: %v", migratedTemplateErr)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(path, migratedTemplateBytes, 0o600); err != nil {
		tb.Fatal(err)
	}
}

func buildMigratedTemplate() ([]byte, error) {
	ctx := context.Background()
	dir, err := os.MkdirTemp("", "veritra-migrated-template-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "template.db")
	store, err := Open(ctx, config.Config{Addr: ":0", DataDir: dir, DatabasePath: path, StoragePath: filepath.Join(dir, "blobs")})
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
