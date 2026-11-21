package storage

import (
	"context"
	"database/sql"
	"io/fs"
	"strings"
	"testing"
	"testing/fstest"

	"private-messenger/server/migrations"
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

// Rollback across a schema change (docs/operations.md, "Upgrade and
// rollback"): an older binary knows fewer migrations than the database has
// applied. Migrate leaves the newer ones alone and starts; it neither
// re-applies, drops nor rewrites them. This pins that behaviour (a decision
// for the release owner, not an accident: a refusal would break the Flux
// revert path) and that an edited migration the old binary does know is still
// refused. Whether the old code works on the newer schema is a rehearsal,
// scripts/rehearse-schema-rollback.sh.
func TestMigrateOnANewerDatabaseLeavesUnknownMigrationsAloneAndStillRefusesEdits(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	a := `CREATE TABLE a_thing (id TEXT PRIMARY KEY);`
	b := `CREATE TABLE b_thing (id TEXT PRIMARY KEY, extra TEXT NOT NULL DEFAULT '');`
	newer := fstest.MapFS{"0001_a.sql": {Data: []byte(a)}, "0002_b.sql": {Data: []byte(b)}}
	if err := store.Migrate(ctx, newer); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `INSERT INTO b_thing(id, extra) VALUES('row', 'kept')`); err != nil {
		t.Fatal(err)
	}
	older := fstest.MapFS{"0001_a.sql": {Data: []byte(a)}}
	for i := 0; i < 2; i++ {
		if err := store.Migrate(ctx, older); err != nil {
			t.Fatalf("older binary on a newer database, run %d: %v", i, err)
		}
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM schema_migrations`); n != 2 {
		t.Fatalf("schema_migrations rows = %d, want both kept", n)
	}
	if unknown, err := store.UnknownAppliedMigrations(ctx, older); err != nil || len(unknown) != 1 || unknown[0] != "0002_b.sql" {
		t.Fatalf("unknown applied migrations for the older binary = %v, err = %v, want [0002_b.sql]", unknown, err)
	}
	if unknown, err := store.UnknownAppliedMigrations(ctx, newer); err != nil || len(unknown) != 0 {
		t.Fatalf("unknown applied migrations for the newer binary = %v, err = %v, want none", unknown, err)
	}
	var extra string
	if err := store.db.QueryRowContext(ctx, `SELECT extra FROM b_thing WHERE id = 'row'`).Scan(&extra); err != nil || extra != "kept" {
		t.Fatalf("the newer migration's data = %q, err = %v", extra, err)
	}
	// The newer binary comes back: nothing to apply, nothing lost.
	if err := store.Migrate(ctx, newer); err != nil {
		t.Fatalf("rolling forward again: %v", err)
	}
	edited := fstest.MapFS{"0001_a.sql": {Data: []byte(a + " -- edited")}}
	if err := store.Migrate(ctx, edited); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("edited known migration err = %v, want checksum mismatch", err)
	}
}

// Applied migrations are checked by checksum (the whole file, comments
// included), so a database migrated by one text refuses to start on another.
// 0090 and 0091 existed in two byte-different versions before 8eb373f made
// them identical to the sealed branch's (testing/evidence/
// server-schema-rollback-2026-11-21.md, finding 2). These are their checksums
// as on origin/main; any edit, even to a comment, fails here first. The
// earlier text (e9aef04: 0090 abbaab21..., 0091 9025146f...) must never come
// back. Add a migration here once it is on main.
func TestReleasedMigrationChecksumsArePinned(t *testing.T) {
	pinned := map[string]string{
		"0090_l2_sealed_tokens.sql":    "460e7a607585c828f9fbc312e52e493db9686f9bca896082acafa25a17633f91",
		"0091_l2_sealed_envelopes.sql": "4c305a377b5641751181cfa0132a92a006b2ecef010f790e4df3f6b43c7a5e68",
	}
	for name, want := range pinned {
		data, err := fs.ReadFile(migrations.FS, name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if got := migrationChecksum(data); got != want {
			t.Errorf("%s checksum = %s, want %s: an applied migration must never change", name, got, want)
		}
	}
}
