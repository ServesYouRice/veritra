package app

import (
	"context"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/storage/storagetest"
	"private-messenger/server/migrations"
)

// Rolling back to an older binary across a schema change: the binary starts
// (Migrate leaves unknown applied migrations alone) but says so in the log,
// naming the versions and nothing else.
func TestOlderBinaryWarnsThatTheDatabaseIsNewer(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	path := filepath.Join(dir, "private-messenger.db")
	storagetest.SeedMigrated(t, path)
	store, err := storage.Open(ctx, config.Config{Addr: ":0", DataDir: dir, DatabasePath: path, StoragePath: filepath.Join(dir, "blobs")})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}

	// The binary that wrote the database: nothing is unknown, nothing is said.
	var current lockedBuffer
	warnNewerSchema(ctx, slog.New(slog.NewTextHandler(&current, nil)), store, migrations.FS)
	if out := current.String(); out != "" {
		t.Fatalf("a current binary logged %q", out)
	}

	// An older binary carries only the first migration.
	entries, err := migrations.FS.ReadDir(".")
	if err != nil || len(entries) < 3 {
		t.Fatalf("migrations: %d entries, %v", len(entries), err)
	}
	older := fstest.MapFS{entries[0].Name(): {Data: []byte("")}}
	var buffer lockedBuffer
	warnNewerSchema(ctx, slog.New(slog.NewTextHandler(&buffer, nil)), store, older)
	out := buffer.String()
	if !strings.Contains(out, "database_schema_newer_than_binary") || !strings.Contains(out, "level=WARN") {
		t.Fatalf("no warning for a newer database: %q", out)
	}
	last := ""
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".sql") {
			last = entry.Name()
		}
	}
	if !strings.Contains(out, last) {
		t.Fatalf("the warning does not name the newest unknown migration %q: %q", last, out)
	}
}
