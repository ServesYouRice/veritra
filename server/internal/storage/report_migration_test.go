package storage

import (
	"bytes"
	"context"
	"testing"

	"private-messenger/server/migrations"
)

// C6, migration 0047: an existing database keeps its envelopes (unfranked, so
// NULL), and the new column is 32 bytes and write-once.
func TestReportsMigrationUpgradesExistingEnvelopes(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0046")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	seedHistorical(t, store)
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatalf("upgrade to 0047: %v", err)
	}

	var commit []byte
	var ciphertext []byte
	if err := store.db.QueryRowContext(ctx, `SELECT frank_commit, ciphertext FROM message_envelopes WHERE id = 'msg_1'`).Scan(&commit, &ciphertext); err != nil {
		t.Fatal(err)
	}
	if commit != nil || !bytes.Equal(ciphertext, []byte{0xC1, 0xC2, 0xC3}) {
		t.Fatalf("commit=%x ciphertext=%x", commit, ciphertext)
	}

	// An unfranked envelope may not gain a commitment later either.
	if _, err := store.db.ExecContext(ctx, `UPDATE message_envelopes SET frank_commit = zeroblob(32) WHERE id = 'msg_1'`); err == nil {
		t.Fatal("frank_commit set after insert")
	}
	// Only 32 bytes, or NULL, at insert.
	insert := `INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, frank_commit, attachment_refs_json, created_at)
		VALUES(?, 'conv_dm', 'acct_a', 'dev_a', ?, X'01', 'mls10-openmls-v1', '{}', ?, '[]', '2026-01-02T00:00:00Z')`
	if _, err := store.db.ExecContext(ctx, insert, "msg_short", "k-short", []byte{1, 2, 3}); err == nil {
		t.Fatal("short frank_commit stored")
	}
	if _, err := store.db.ExecContext(ctx, insert, "msg_ok", "k-ok", bytes.Repeat([]byte{1}, 32)); err != nil {
		t.Fatalf("32-byte frank_commit refused: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE message_envelopes SET frank_commit = zeroblob(32) WHERE id = 'msg_ok'`); err == nil {
		t.Fatal("frank_commit changed after insert")
	}

	// A report copy refuses a sealed blob outside the Rust core's size bounds
	// and a short report id. It has no column for the message (D95).
	report := `INSERT INTO reports(id, report_id, inbox_kind, inbox_id, key_rev, recipient_public_key, conversation_id, reporter_account_id, sealed, created_at)
		VALUES(?, ?, 'instance_owner', 'acct_a', 1, ?, 'conv_dm', 'acct_b', ?, '2026-01-03T00:00:00Z')`
	key := bytes.Repeat([]byte{7}, 32)
	if _, err := store.db.ExecContext(ctx, report, "rpt_1", "rpt-migration-0001", key, []byte{1}); err == nil {
		t.Fatal("report with a tiny sealed blob stored")
	}
	if _, err := store.db.ExecContext(ctx, report, "rpt_2", "short", key, bytes.Repeat([]byte{1}, 60)); err == nil {
		t.Fatal("report with a short report id stored")
	}
	if _, err := store.db.ExecContext(ctx, report, "rpt_3", "rpt-migration-0001", key, bytes.Repeat([]byte{1}, 60)); err != nil {
		t.Fatalf("valid report refused: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, report, "rpt_4", "rpt-migration-0001", key, bytes.Repeat([]byte{1}, 60)); err == nil {
		t.Fatal("the same report id stored twice for one reporter and inbox")
	}
}
