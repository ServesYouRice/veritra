package storage

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"testing/fstest"
)

// legacyMigrationStore is a store whose schema_migrations table predates the
// checksum column, with one applied row (0002_b.sql) whose migration ran.
func legacyMigrationStore(t *testing.T, ctx context.Context) *Store {
	t.Helper()
	store := openBareStore(t)
	t.Cleanup(func() { store.Close() })
	for _, statement := range []string{
		`CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`CREATE TABLE b_thing (id TEXT PRIMARY KEY)`,
		`INSERT INTO schema_migrations(version, applied_at) VALUES('0002_b.sql', '2026-01-01T00:00:00Z')`,
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
	return store
}

func storedChecksum(t *testing.T, ctx context.Context, store *Store, version string) sql.NullString {
	t.Helper()
	var checksum sql.NullString
	if err := store.db.QueryRowContext(ctx, `SELECT checksum_sha256 FROM schema_migrations WHERE version = ?`, version).Scan(&checksum); err != nil {
		t.Fatalf("read checksum of %s: %v", version, err)
	}
	return checksum
}

// A new migration that sorts before an applied legacy one and fails must not
// leave the legacy row without its checksum: the column and the backfill are
// one step that finishes before any new migration runs.
func TestMigrateBackfillsLegacyChecksumsBeforeApplyingNewMigrations(t *testing.T) {
	ctx := context.Background()
	store := legacyMigrationStore(t, ctx)
	b := `CREATE TABLE b_thing (id TEXT PRIMARY KEY);`
	broken := fstest.MapFS{
		"0001_new.sql": {Data: []byte(`THIS IS NOT SQL;`)},
		"0002_b.sql":   {Data: []byte(b)},
	}
	if err := store.Migrate(ctx, broken); err == nil {
		t.Fatal("a broken new migration applied")
	}
	if checksum := storedChecksum(t, ctx, store, "0002_b.sql"); !checksum.Valid || checksum.String != migrationChecksum([]byte(b)) {
		t.Fatalf("legacy row checksum after the failed run = %#v, want the file's checksum", checksum)
	}
	fixed := fstest.MapFS{
		"0001_new.sql": {Data: []byte(`CREATE TABLE new_thing (id TEXT PRIMARY KEY);`)},
		"0002_b.sql":   {Data: []byte(b)},
	}
	if err := store.Migrate(ctx, fixed); err != nil {
		t.Fatalf("migrate after fixing the new migration: %v", err)
	}
	if checksum := storedChecksum(t, ctx, store, "0001_new.sql"); !checksum.Valid || checksum.String == "" {
		t.Fatalf("new migration checksum = %#v", checksum)
	}
	// An edited applied migration is still refused.
	edited := fstest.MapFS{
		"0001_new.sql": fixed["0001_new.sql"],
		"0002_b.sql":   {Data: []byte(b + " -- edited")},
	}
	if err := store.Migrate(ctx, edited); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("edited migration err = %v, want checksum mismatch", err)
	}
}

// If the backfill itself fails, the column is not left behind: the next start
// sees the same legacy table and tries again.
func TestMigrateLeavesNoChecksumColumnWhenTheBackfillFails(t *testing.T) {
	ctx := context.Background()
	store := legacyMigrationStore(t, ctx)
	b := `CREATE TABLE b_thing (id TEXT PRIMARY KEY);`
	files := fstest.MapFS{"0002_b.sql": {Data: []byte(b)}}
	// A trigger that aborts every UPDATE of schema_migrations makes the
	// backfill fail after the column has been added.
	if _, err := store.db.ExecContext(ctx, `CREATE TRIGGER fail_backfill BEFORE UPDATE ON schema_migrations BEGIN SELECT RAISE(ABORT, 'injected backfill failure'); END`); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, files); err == nil || !strings.Contains(err.Error(), "injected backfill failure") {
		t.Fatalf("migrate err = %v, want the injected failure", err)
	}
	var hasColumn int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pragma_table_info('schema_migrations') WHERE name = 'checksum_sha256'`).Scan(&hasColumn); err != nil {
		t.Fatal(err)
	}
	if hasColumn != 0 {
		t.Fatal("the checksum column survived a failed backfill")
	}
	if _, err := store.db.ExecContext(ctx, `DROP TRIGGER fail_backfill`); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, files); err != nil {
		t.Fatalf("retry after the failure: %v", err)
	}
	if checksum := storedChecksum(t, ctx, store, "0002_b.sql"); !checksum.Valid || checksum.String != migrationChecksum([]byte(b)) {
		t.Fatalf("checksum after the retry = %#v", checksum)
	}
}

// A database that already has the column and a NULL checksum stays a hard
// error (Q-003 is undecided); nothing repairs it silently.
func TestMigrateKeepsRefusingARowWithoutChecksumWhenTheColumnExists(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	defer store.Close()
	for _, statement := range []string{
		`CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, checksum_sha256 TEXT, applied_at TEXT NOT NULL)`,
		`CREATE TABLE b_thing (id TEXT PRIMARY KEY)`,
		`INSERT INTO schema_migrations(version, checksum_sha256, applied_at) VALUES('0002_b.sql', NULL, '2026-01-01T00:00:00Z')`,
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	files := fstest.MapFS{"0002_b.sql": {Data: []byte(`CREATE TABLE b_thing (id TEXT PRIMARY KEY);`)}}
	if err := store.Migrate(ctx, files); err == nil || !strings.Contains(err.Error(), "has no stored checksum") {
		t.Fatalf("migrate err = %v, want the missing-checksum refusal", err)
	}
}
