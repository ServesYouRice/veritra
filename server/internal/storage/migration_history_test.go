package storage

import (
	"bytes"
	"context"
	"database/sql"
	"io/fs"
	"path/filepath"
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
