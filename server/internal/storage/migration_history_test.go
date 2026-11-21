package storage

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"testing/fstest"

	"private-messenger/server/internal/config"
	"private-messenger/server/migrations"
)

// QA09 (card I45): databases built by earlier releases upgrade in place,
// keep their ciphertext rows, get correct defaults, and a failing migration
// leaves nothing behind.

func migrationsUpTo(t *testing.T, lastPrefix string) (fs.FS, []string) {
	t.Helper()
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		t.Fatal(err)
	}
	subset := fstest.MapFS{}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".sql") {
			continue
		}
		names = append(names, name)
		if name[:4] <= lastPrefix {
			data, err := fs.ReadFile(migrations.FS, name)
			if err != nil {
				t.Fatal(err)
			}
			subset[name] = &fstest.MapFile{Data: data}
		}
	}
	sort.Strings(names)
	return subset, names
}

func openBareStore(t *testing.T) *Store {
	store, _ := openBareStoreAt(t)
	return store
}

func openBareStoreAt(t *testing.T) (*Store, string) {
	t.Helper()
	dir := t.TempDir()
	store, err := Open(context.Background(), config.Config{
		DataDir: dir, DatabasePath: filepath.Join(dir, "history.db"), StoragePath: filepath.Join(dir, "blobs"),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	return store, filepath.Join(dir, "history.db")
}

// seedHistorical inserts rows using only columns every release has had.
func seedHistorical(t *testing.T, store *Store) {
	t.Helper()
	now := "2026-01-01T00:00:00Z"
	statements := []struct {
		sql  string
		args []interface{}
	}{
		{`INSERT INTO instances(id, name, setup_complete, created_at, updated_at) VALUES(1, 'Old', 1, ?, ?)`, []interface{}{now, now}},
		{`INSERT INTO accounts(id, username, password_hash, role, status, created_at) VALUES('acct_a', 'alice', 'h', 'owner', 'active', ?)`, []interface{}{now}},
		{`INSERT INTO accounts(id, username, password_hash, role, status, created_at) VALUES('acct_b', 'bob', 'h', 'member', 'active', ?)`, []interface{}{now}},
		{`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_a', 'acct_a', 'a', X'01', ?)`, []interface{}{now}},
		{`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_b', 'acct_b', 'b', X'01', ?)`, []interface{}{now}},
		{`INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at) VALUES('tok', 'acct_a', 'dev_a', '2027-01-01T00:00:00Z', ?)`, []interface{}{now}},
		{`INSERT INTO conversations(id, kind, created_by, created_at) VALUES('conv_dm', 'dm', 'acct_a', ?)`, []interface{}{now}},
		{`INSERT INTO memberships(conversation_id, account_id, role, created_at) VALUES('conv_dm', 'acct_a', 'owner', ?)`, []interface{}{now}},
		{`INSERT INTO memberships(conversation_id, account_id, role, created_at) VALUES('conv_dm', 'acct_b', 'member', ?)`, []interface{}{now}},
		{`INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at)
			VALUES('msg_1', 'conv_dm', 'acct_a', 'dev_a', 'k1', X'C1C2C3', 'mls10-openmls-v1', '{}', '[]', ?)`, []interface{}{now}},
		{`INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at)
			VALUES('message.envelope.created', NULL, 'conv_dm', '{"message_id":"msg_1"}', ?)`, []interface{}{now}},
		{`INSERT INTO call_sessions(id, conversation_id, created_by, state, metadata_json, created_at) VALUES('call_1', 'conv_dm', 'acct_a', 'ringing', '{}', ?)`, []interface{}{now}},
	}
	for _, statement := range statements {
		if _, err := store.db.ExecContext(context.Background(), statement.sql, statement.args...); err != nil {
			t.Fatalf("seed %q: %v", statement.sql[:40], err)
		}
	}
}

func TestHistoricalDatabasesUpgradeToCurrent(t *testing.T) {
	ctx := context.Background()
	for _, point := range []string{"0020", "0023", "0027"} {
		t.Run(point, func(t *testing.T) {
			store, path := openBareStoreAt(t)
			old, all := migrationsUpTo(t, point)
			if err := store.Migrate(ctx, old); err != nil {
				t.Fatalf("build %s database: %v", point, err)
			}
			seedHistorical(t, store)
			if err := store.Migrate(ctx, migrations.FS); err != nil {
				t.Fatalf("upgrade from %s: %v", point, err)
			}
			// Reapplying is a no-op.
			if err := store.Migrate(ctx, migrations.FS); err != nil {
				t.Fatalf("reapply: %v", err)
			}
			var applied int
			if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations`).Scan(&applied); err != nil || applied != len(all) {
				t.Fatalf("applied=%d want %d err=%v", applied, len(all), err)
			}
			var ciphertext []byte
			if err := store.db.QueryRowContext(ctx, `SELECT ciphertext FROM message_envelopes WHERE id = 'msg_1'`).Scan(&ciphertext); err != nil ||
				!bytes.Equal(ciphertext, []byte{0xC1, 0xC2, 0xC3}) {
				t.Fatalf("ciphertext=%x err=%v", ciphertext, err)
			}
			// Session lifetimes (0027) are backfilled from creation time.
			var lastUsed, absolute sql.NullString
			if err := store.db.QueryRowContext(ctx, `SELECT last_used_at, absolute_expires_at FROM sessions WHERE token_hash = 'tok'`).Scan(&lastUsed, &absolute); err != nil {
				t.Fatal(err)
			}
			if point < "0027" && (lastUsed.String != "2026-01-01T00:00:00Z" || !strings.HasPrefix(absolute.String, "2026-01-31")) {
				t.Fatalf("session lifetime last_used=%q absolute=%q", lastUsed.String, absolute.String)
			}
			// Call authorization (0028): a legacy two-person DM call names
			// its invitee.
			var invited string
			var version int
			if err := store.db.QueryRowContext(ctx, `SELECT invited_account_id, version FROM call_sessions WHERE id = 'call_1'`).Scan(&invited, &version); err != nil {
				t.Fatal(err)
			}
			if invited != "acct_b" || version != 1 {
				t.Fatalf("call invited=%q version=%d", invited, version)
			}
			// Durable push (0026) and MLS rosters (0029) start empty, and the
			// legacy conversation stays unfiltered.
			for _, table := range []string{"push_wake_jobs", "conversation_mls_groups", "conversation_mls_devices", "mls_revocations", "conversation_mls_messages"} {
				var count int
				if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM `+table).Scan(&count); err != nil || count != 0 {
					t.Fatalf("%s count=%d err=%v", table, count, err)
				}
			}
			events, err := store.ListSyncEvents(ctx, "acct_b", "dev_b", 0, 10)
			if err != nil || len(events) != 1 {
				t.Fatalf("legacy events=%d err=%v", len(events), err)
			}
			if err := ValidateDatabaseFile(ctx, path); err != nil {
				t.Fatalf("upgraded database fails validation: %v", err)
			}
		})
	}
}

func TestAFailingMigrationRollsBackAtomically(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	broken := fstest.MapFS{}
	current, _ := migrationsUpTo(t, "9999")
	for name, file := range current.(fstest.MapFS) {
		broken[name] = file
	}
	broken["9998_broken.sql"] = &fstest.MapFile{Data: []byte(`
CREATE TABLE half_applied(x INTEGER);
ALTER TABLE accounts ADD COLUMN half_applied TEXT;
INSERT INTO table_that_does_not_exist VALUES(1);
`)}
	if err := store.Migrate(ctx, broken); err == nil || !strings.Contains(err.Error(), "9998_broken.sql") {
		t.Fatalf("broken migration err=%v", err)
	}
	var tables int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE name = 'half_applied'`).Scan(&tables); err != nil || tables != 0 {
		t.Fatalf("half-applied table survived: %d %v", tables, err)
	}
	var columns int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pragma_table_info('accounts') WHERE name = 'half_applied'`).Scan(&columns); err != nil || columns != 0 {
		t.Fatalf("half-applied column survived: %d %v", columns, err)
	}
	var recorded int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE version = '9998_broken.sql'`).Scan(&recorded); err != nil || recorded != 0 {
		t.Fatalf("broken migration recorded: %d %v", recorded, err)
	}
	// The instance still migrates normally afterwards.
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
}

// T49B: a database migrated before 0031 gets blob usage counters
// backfilled from its attachment and backup rows.
func TestBlobUsageBackfillOnUpgrade(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0030")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	seedHistorical(t, store)
	for i, row := range []struct {
		table, owner string
		size         int64
	}{{"attachment_envelopes", "acct_a", 100}, {"attachment_envelopes", "acct_a", 23}, {"attachment_envelopes", "acct_b", 7}, {"backup_blobs", "acct_a", 1000}} {
		var err error
		if row.table == "attachment_envelopes" {
			_, err = store.db.ExecContext(ctx, `INSERT INTO attachment_envelopes(id, owner_account_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at) VALUES(?, ?, ?, 'x', ?, '{}', '2026-01-01T00:00:00Z')`,
				fmt.Sprintf("att_%d", i), row.owner, fmt.Sprintf("blob_%d", i), row.size)
		} else {
			_, err = store.db.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, storage_key, size_bytes, key_derivation_metadata_json, created_at) VALUES(?, ?, ?, ?, '{}', '2026-01-01T00:00:00Z')`,
				fmt.Sprintf("bak_%d", i), row.owner, fmt.Sprintf("blob_%d", i), row.size)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	counters, total, _, _ := blobUsage(t, store)
	if !reflect.DeepEqual(counters, map[string]int64{"acct_a": 1123, "acct_b": 7}) || total != 1130 {
		t.Fatalf("backfill counters=%v total=%d", counters, total)
	}
	checkBlobUsageMatches(t, store, "after upgrade")
}

// Two migration files with one number apply in name order, which hides a
// merge that brought both (0094 did, from two branches). Every number is
// used once.
func TestMigrationNumbersAreUnique(t *testing.T) {
	_, names := migrationsUpTo(t, "")
	seen := map[string]string{}
	for _, name := range names {
		if len(name) < 5 || name[4] != '_' {
			t.Fatalf("migration %s does not start with a four-digit number", name)
		}
		if other, ok := seen[name[:4]]; ok {
			t.Fatalf("migrations %s and %s share a number", other, name)
		}
		seen[name[:4]] = name
	}
}

// Rollback (handbook deploy path; operations.md "Kubernetes (k3s)"): the
// previous image starts on a database the newer image already migrated. Its
// migrate step must succeed without touching the newer migrations' records,
// so reverting the release commit in infra brings the old server back. This
// covers only the migrate step: whether the old code works on the newer
// columns is each migration's own compatibility (VE-05).
func TestOlderBinaryMigrateIsANoOpOnANewerSchema(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	_, names := migrationsUpTo(t, "0000")
	if len(names) < 2 {
		t.Fatalf("need at least two migrations, have %v", names)
	}
	newest := names[len(names)-1]
	older, _ := migrationsUpTo(t, fmt.Sprintf("%04d", mustAtoi(t, newest[:4])-1))
	if _, err := fs.Stat(older, newest); err == nil {
		t.Fatalf("the older migration set still holds %s", newest)
	}
	before := appliedMigrationRows(t, ctx, store)
	if err := store.Migrate(ctx, older); err != nil {
		t.Fatalf("older binary refused the newer schema: %v", err)
	}
	if after := appliedMigrationRows(t, ctx, store); !reflect.DeepEqual(before, after) {
		t.Fatalf("older migrate changed the history:\nbefore %v\nafter  %v", before, after)
	}
	if _, ok := before[newest]; !ok {
		t.Fatalf("history has no row for the newest migration %s", newest)
	}
}

func mustAtoi(t *testing.T, digits string) int {
	t.Helper()
	var n int
	if _, err := fmt.Sscanf(digits, "%d", &n); err != nil {
		t.Fatalf("migration prefix %q: %v", digits, err)
	}
	return n
}

func appliedMigrationRows(t *testing.T, ctx context.Context, store *Store) map[string]string {
	t.Helper()
	rows, err := store.db.QueryContext(ctx, `SELECT version, checksum_sha256 || '@' || applied_at FROM schema_migrations`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var version, value string
		if err := rows.Scan(&version, &value); err != nil {
			t.Fatal(err)
		}
		out[version] = value
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}
