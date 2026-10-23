package app

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
	"private-messenger/server/migrations"
)

// Card I35 acceptance: one scheduled sweep drains 1,200 eligible records per
// class, cancellation stops promptly, attachment rows and blobs stay
// consistent, and sustained ingest stays below the documented backlog target
// (docs/operations.md: 1,200 rows, oldest age below one sweep interval).

const (
	retentionTestLayout   = "2006-01-02T15:04:05.000000000Z"
	retentionTestAccount  = "acct_retention_owner"
	retentionTestDevice   = "dev_retention_owner"
	retentionTestConv     = "conv_retention"
	retentionBacklogLimit = 1200
	retentionSweepPeriod  = 6 * time.Hour
)

type retentionHarness struct {
	app   *App
	db    *sql.DB
	blobs *uploads.LocalStore
	dir   string
	logs  *bytes.Buffer
	seq   int
}

func newRetentionHarness(t *testing.T) *retentionHarness {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	path := filepath.Join(dir, "retention.db")
	store, err := storage.Open(ctx, config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: path,
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "test",
	})
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatalf("open raw db: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	blobs, err := uploads.NewLocalStore(filepath.Join(dir, "blobs"))
	if err != nil {
		t.Fatalf("open blob store: %v", err)
	}
	logs := &bytes.Buffer{}
	h := &retentionHarness{
		app: &App{
			Config:  config.Config{SyncRetention: 30 * 24 * time.Hour},
			Store:   store,
			Blobs:   blobs,
			Log:     slog.New(slog.NewTextHandler(logs, nil)),
			metrics: newHTTPMetrics(),
			// Race-instrumented SQLite is many times slower than a release
			// build; the generous clock leaves the 64-batch ceiling in charge.
			retentionBudget: 5 * time.Minute,
		},
		db:    db,
		blobs: blobs,
		dir:   filepath.Join(dir, "blobs"),
		logs:  logs,
	}
	created := stamp(time.Now().Add(-90 * 24 * time.Hour))
	h.exec(t, `INSERT INTO accounts(id, username, password_hash, role, created_at) VALUES (?, 'retention', 'x', 'owner', ?)`, retentionTestAccount, created)
	h.exec(t, `INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES (?, ?, 'phone', x'01', ?)`, retentionTestDevice, retentionTestAccount, created)
	h.exec(t, `INSERT INTO conversations(id, kind, created_by, created_at) VALUES (?, 'group', ?, ?)`, retentionTestConv, retentionTestAccount, created)
	return h
}

func stamp(value time.Time) string { return value.UTC().Format(retentionTestLayout) }

func (h *retentionHarness) exec(t *testing.T, query string, args ...any) {
	t.Helper()
	if _, err := h.db.Exec(query, args...); err != nil {
		t.Fatalf("exec %q: %v", query, err)
	}
}

func (h *retentionHarness) count(t *testing.T, query string, args ...any) int {
	t.Helper()
	var n int
	if err := h.db.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", query, err)
	}
	return n
}

func (h *retentionHarness) next() int {
	h.seq++
	return h.seq
}

// seedExpired inserts n expired rows in each swept class: messages that each
// own one attachment (so the sweep also creates n blob deletions), call
// sessions, and expired login sessions. Storage keys are valid but have no
// file, which LocalStore.Delete treats as already deleted.
func (h *retentionHarness) seedExpired(t *testing.T, n int, expiredAt time.Time) {
	t.Helper()
	tx, err := h.db.Begin()
	if err != nil {
		t.Fatalf("begin seed: %v", err)
	}
	defer tx.Rollback()
	expired := stamp(expiredAt)
	created := stamp(expiredAt.Add(-time.Hour))
	for i := 0; i < n; i++ {
		id := h.next()
		message := fmt.Sprintf("msg_retention_%06d", id)
		attachment := fmt.Sprintf("att_retention_%06d", id)
		statements := []struct {
			query string
			args  []any
		}{
			{`INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at, expires_at)
				VALUES (?, ?, ?, ?, ?, x'01', 'mls', '{}', '[]', ?, ?)`, []any{message, retentionTestConv, retentionTestAccount, retentionTestDevice, message, created, expired}},
			{`INSERT INTO attachment_envelopes(id, owner_account_id, conversation_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at)
				VALUES (?, ?, ?, ?, ?, 1, '{}', ?)`, []any{attachment, retentionTestAccount, retentionTestConv, fmt.Sprintf("blob_%032x", id), strings.Repeat("a", 64), created}},
			{`INSERT INTO message_attachments(message_id, attachment_id) VALUES (?, ?)`, []any{message, attachment}},
			{`INSERT INTO call_sessions(id, conversation_id, created_by, state, metadata_json, created_at, expires_at, create_action_id)
				VALUES (?, ?, ?, 'ended', '{}', ?, ?, ?)`, []any{fmt.Sprintf("call_retention_%06d", id), retentionTestConv, retentionTestAccount, created, expired, fmt.Sprintf("action_%06d", id)}},
			{`INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?)`,
				[]any{fmt.Sprintf("session_retention_%06d", id), retentionTestAccount, retentionTestDevice, expired, created}},
		}
		for _, statement := range statements {
			if _, err := tx.Exec(statement.query, statement.args...); err != nil {
				t.Fatalf("seed %q: %v", statement.query, err)
			}
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit seed: %v", err)
	}
}

// sweep runs the bounded retention steps in the order runRetentionSweeper's
// scheduled sweep uses, then refreshes the backlog metrics.
func (h *retentionHarness) sweep(ctx context.Context) {
	a := h.app
	now := time.Now().UTC()
	a.drainExpiredContent(ctx, now)
	a.reconcileBlobDeletions(ctx)
	a.drainRetention(ctx, "call_sessions", func() (int64, error) { return a.Store.PruneCallSessions(ctx, time.Now().UTC()) })
	a.drainRetention(ctx, "operational_rows", func() (int64, error) { return a.Store.PruneOperationalRows(ctx, time.Now().UTC()) })
	a.updateRetentionMetrics(ctx, time.Now().UTC())
}

func (h *retentionHarness) assertDrained(t *testing.T) {
	t.Helper()
	for _, query := range []string{
		`SELECT COUNT(*) FROM message_envelopes`,
		`SELECT COUNT(*) FROM message_attachments`,
		`SELECT COUNT(*) FROM attachment_envelopes`,
		`SELECT COUNT(*) FROM call_sessions`,
		`SELECT COUNT(*) FROM sessions`,
		`SELECT COUNT(*) FROM blob_deletion_queue`,
	} {
		if remaining := h.count(t, query); remaining != 0 {
			t.Fatalf("%s = %d after one sweep, want 0", query, remaining)
		}
	}
	if rows, age := h.app.metrics.retentionBacklog.Load(), h.app.metrics.retentionOldestAge.Load(); rows != 0 || age != 0 {
		t.Fatalf("backlog metrics rows=%d oldest_age=%d after a full sweep, want 0", rows, age)
	}
}

func TestRetentionSweepDrains1200RowsPerClass(t *testing.T) {
	h := newRetentionHarness(t)
	h.seedExpired(t, 1200, time.Now().Add(-time.Hour))
	ctx := context.Background()
	backlog, err := h.app.Store.RetentionBacklog(ctx, time.Now().UTC())
	if err != nil {
		t.Fatalf("read backlog: %v", err)
	}
	// Messages, call sessions and login sessions: 1,200 eligible rows each.
	if backlog.Rows != 3*1200 {
		t.Fatalf("backlog rows before sweep = %d, want %d", backlog.Rows, 3*1200)
	}
	h.sweep(ctx)
	h.assertDrained(t)
	if strings.Contains(h.logs.String(), "level=WARN") {
		t.Fatalf("sweep logged a warning: %s", h.logs.String())
	}
}

func TestRetentionBacklogCountsOnlyRowsTheSweepCanPrune(t *testing.T) {
	h := newRetentionHarness(t)
	now := time.Now()
	recent := stamp(now.Add(-time.Hour))                                             // inside the 30-day grace
	old := stamp(now.Add(-storage.OperationalRowRetention - 2*retentionSweepPeriod)) // prunable for 12 hours
	future := stamp(now.Add(time.Hour))
	// One row inside its grace period and one prunable row per operational class.
	h.exec(t, `INSERT INTO invites(id, code, created_by, created_at, expires_at, revoked_at) VALUES
		('inv_grace_expired', 'c1', ?, ?, ?, NULL), ('inv_grace_revoked', 'c2', ?, ?, ?, ?), ('inv_old', 'c3', ?, ?, ?, NULL)`,
		retentionTestAccount, recent, recent, retentionTestAccount, recent, future, recent, retentionTestAccount, old, old)
	h.exec(t, `INSERT INTO device_links(id, code, account_id, state, verification_code, created_at, expires_at) VALUES
		('dl_grace', 'd1', ?, 'consumed', 'v', ?, ?), ('dl_old', 'd2', ?, 'revoked', 'v', ?, ?)`,
		retentionTestAccount, recent, recent, retentionTestAccount, old, old)
	h.exec(t, `INSERT INTO enrollment_reservations(id, kind, account_id, device_id, challenge, created_at, expires_at, consumed_at) VALUES
		('er_grace', 'register', 'acct_er1', 'dev_er1', zeroblob(32), ?, ?, ?), ('er_old', 'register', 'acct_er2', 'dev_er2', zeroblob(32), ?, ?, ?)`,
		recent, future, recent, old, future, old)
	h.exec(t, `INSERT INTO push_subscriptions(id, account_id, provider, endpoint, created_at, disabled_at) VALUES
		('ps_grace', ?, 'fcm', 'e1', ?, ?), ('ps_old', ?, 'fcm', 'e2', ?, ?)`,
		retentionTestAccount, recent, recent, retentionTestAccount, old, old)
	h.exec(t, `INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at, claimed_at) VALUES
		('kp_grace', ?, x'01', 's', ?, ?, ?), ('kp_old', ?, x'01', 's', ?, ?, ?)`,
		retentionTestDevice, recent, future, recent, retentionTestDevice, old, future, old)

	ctx := context.Background()
	backlog, err := h.app.Store.RetentionBacklog(ctx, time.Now().UTC())
	if err != nil {
		t.Fatalf("read backlog: %v", err)
	}
	if backlog.Rows != 5 {
		t.Fatalf("backlog rows = %d, want the 5 prunable rows only", backlog.Rows)
	}
	// Age counts from when a row became prunable, not from its timestamp.
	if age := time.Duration(backlog.OldestAgeSecond) * time.Second; age < 2*retentionSweepPeriod-time.Minute || age > 2*retentionSweepPeriod+time.Minute {
		t.Fatalf("oldest backlog age = %s, want about %s", age, 2*retentionSweepPeriod)
	}
	h.sweep(ctx)
	if rows, age := h.app.metrics.retentionBacklog.Load(), h.app.metrics.retentionOldestAge.Load(); rows != 0 || age != 0 {
		t.Fatalf("backlog metrics rows=%d oldest_age=%d after a full sweep, want 0", rows, age)
	}
	for table, want := range map[string]int{"invites": 2, "device_links": 1, "enrollment_reservations": 1, "push_subscriptions": 1, "device_key_packages": 1} {
		if got := h.count(t, `SELECT COUNT(*) FROM `+table); got != want {
			t.Fatalf("%s rows kept = %d, want %d grace rows", table, got, want)
		}
	}
}

func TestRetentionSustainedIngestStaysBelowBacklogTarget(t *testing.T) {
	h := newRetentionHarness(t)
	ctx := context.Background()
	// Each sweep interval adds more newly expired rows per class than the
	// documented 1,200-row target; every sweep must still bring it back down.
	for round := 0; round < 2; round++ {
		h.seedExpired(t, 1300, time.Now().Add(-time.Minute))
		h.sweep(ctx)
		rows, age := h.app.metrics.retentionBacklog.Load(), time.Duration(h.app.metrics.retentionOldestAge.Load())*time.Second
		if rows >= retentionBacklogLimit || age >= retentionSweepPeriod {
			t.Fatalf("round %d: backlog rows=%d oldest_age=%s, want below %d rows and %s", round, rows, age, retentionBacklogLimit, retentionSweepPeriod)
		}
	}
	h.assertDrained(t)
}

func TestRetentionAttachmentRowsAndBlobsStayConsistent(t *testing.T) {
	h := newRetentionHarness(t)
	ctx := context.Background()
	put := func() string {
		t.Helper()
		ref, err := h.blobs.PutEncryptedBlob(ctx, strings.NewReader("ciphertext"))
		if err != nil {
			t.Fatalf("put blob: %v", err)
		}
		return ref.StorageKey
	}
	now := time.Now()
	attach := func(id, key string, created time.Time) {
		h.exec(t, `INSERT INTO attachment_envelopes(id, owner_account_id, conversation_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at)
			VALUES (?, ?, ?, ?, ?, 10, '{}', ?)`, id, retentionTestAccount, retentionTestConv, key, strings.Repeat("b", 64), stamp(created))
	}
	message := func(id string, expires *time.Time) {
		var expiresAt any
		if expires != nil {
			expiresAt = stamp(*expires)
		}
		h.exec(t, `INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at, expires_at)
			VALUES (?, ?, ?, ?, ?, x'01', 'mls', '{}', '[]', ?, ?)`, id, retentionTestConv, retentionTestAccount, retentionTestDevice, id, stamp(now.Add(-2*time.Hour)), expiresAt)
	}
	expired := now.Add(-time.Hour)
	later := now.Add(time.Hour)
	keyExpired, keyAlive, keyLongLived, keyOldOrphan, keyNewOrphan := put(), put(), put(), put(), put()
	message("msg_expired", &expired)
	message("msg_alive", &later)
	message("msg_long_lived", nil)
	attach("att_expired", keyExpired, now.Add(-2*time.Hour))
	attach("att_alive", keyAlive, now.Add(-2*time.Hour))
	attach("att_long_lived", keyLongLived, now.Add(-72*time.Hour))
	attach("att_old_orphan", keyOldOrphan, now.Add(-48*time.Hour)) // abandoned upload
	attach("att_new_orphan", keyNewOrphan, now.Add(-time.Minute))  // upload still being sent
	h.exec(t, `INSERT INTO message_attachments(message_id, attachment_id) VALUES ('msg_expired', 'att_expired'), ('msg_alive', 'att_alive'), ('msg_long_lived', 'att_long_lived')`)

	h.sweep(ctx)

	if got := h.count(t, `SELECT COUNT(*) FROM message_envelopes WHERE id = 'msg_expired'`); got != 0 {
		t.Fatal("expired message survived the sweep")
	}
	if got := h.count(t, `SELECT COUNT(*) FROM message_attachments`); got != 2 {
		t.Fatalf("message attachment links = %d, want the 2 live links", got)
	}
	for id, want := range map[string]int{"att_expired": 0, "att_alive": 1, "att_long_lived": 1, "att_old_orphan": 0, "att_new_orphan": 1} {
		if got := h.count(t, `SELECT COUNT(*) FROM attachment_envelopes WHERE id = ?`, id); got != want {
			t.Fatalf("attachment %s rows = %d, want %d", id, got, want)
		}
	}
	if got := h.count(t, `SELECT COUNT(*) FROM blob_deletion_queue`); got != 0 {
		t.Fatalf("blob deletions still queued after reconcile: %d", got)
	}
	for key, want := range map[string]bool{keyExpired: false, keyAlive: true, keyLongLived: true, keyOldOrphan: false, keyNewOrphan: true} {
		_, err := os.Stat(filepath.Join(h.dir, key))
		if exists := err == nil; exists != want {
			t.Fatalf("blob for %s exists=%v want %v (err=%v)", key, exists, want, err)
		}
	}
	// Every surviving attachment row still has its blob.
	rows, err := h.db.Query(`SELECT storage_key FROM attachment_envelopes`)
	if err != nil {
		t.Fatalf("list attachments: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			t.Fatalf("scan attachment: %v", err)
		}
		if _, err := os.Stat(filepath.Join(h.dir, key)); err != nil {
			t.Fatalf("surviving attachment lost its blob: %v", err)
		}
	}
}

func TestRetentionDrainStopsAtCancellationAndWorkCeiling(t *testing.T) {
	h := newRetentionHarness(t)
	ctx, cancel := context.WithCancel(context.Background())
	var calls atomic.Int64
	started := time.Now()
	h.app.drainRetention(ctx, "test", func() (int64, error) {
		if calls.Add(1) == 2 {
			cancel()
		}
		return retentionBatchSize, nil
	})
	if got := calls.Load(); got != 2 {
		t.Fatalf("prune calls after cancellation = %d, want 2", got)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("cancelled drain took %s", elapsed)
	}

	// A class that never empties stops at the batch ceiling.
	calls.Store(0)
	h.app.drainRetention(context.Background(), "test", func() (int64, error) {
		calls.Add(1)
		return retentionBatchSize, nil
	})
	if got := calls.Load(); got != retentionMaxBatches {
		t.Fatalf("prune calls for an endless class = %d, want the %d-batch ceiling", got, retentionMaxBatches)
	}

	// The clock ceiling also ends a class that never empties.
	calls.Store(0)
	h.app.retentionBudget = time.Nanosecond
	h.app.drainRetention(context.Background(), "test", func() (int64, error) {
		calls.Add(1)
		time.Sleep(time.Millisecond)
		return retentionBatchSize, nil
	})
	if got := calls.Load(); got > 1 {
		t.Fatalf("prune calls after the time budget = %d, want at most 1", got)
	}
	h.app.retentionBudget = 5 * time.Minute

	// A failing class stops instead of retrying in a loop.
	calls.Store(0)
	h.app.drainRetention(context.Background(), "test", func() (int64, error) {
		calls.Add(1)
		return 0, errors.New("injected")
	})
	if got := calls.Load(); got != 1 {
		t.Fatalf("prune calls after a failure = %d, want 1", got)
	}
}

func TestRetentionSweeperStopsPromptlyOnCancellation(t *testing.T) {
	h := newRetentionHarness(t)
	h.seedExpired(t, 600, time.Now().Add(-time.Hour))

	// Already cancelled: no batch runs.
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	h.app.drainExpiredContent(cancelled, time.Now().UTC())
	if got := h.count(t, `SELECT COUNT(*) FROM message_envelopes`); got != 600 {
		t.Fatalf("cancelled drain pruned rows: %d remain, want 600", got)
	}

	// The scheduled sweeper returns promptly once its context ends.
	ctx, stop := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.app.runRetentionSweeper(ctx)
	}()
	deadline := time.Now().Add(2 * time.Minute)
	for h.count(t, `SELECT COUNT(*) FROM message_envelopes`) != 0 {
		if time.Now().After(deadline) {
			stop()
			t.Fatal("the first scheduled sweep did not drain the expired messages")
		}
		time.Sleep(10 * time.Millisecond)
	}
	stop()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("retention sweeper did not stop after cancellation")
	}
}
