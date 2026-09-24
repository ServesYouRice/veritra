package app

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/push"
	"private-messenger/server/internal/storage"
	"private-messenger/server/migrations"
)

// Every seeded identifier and push secret carries this marker so a single
// substring check proves none of them reach logs or metric labels.
const pushSentinel = "SENTINEL"

const (
	pushTestProvider     = "fcm"
	pushTestSender       = "acct_SENTINEL_sender_7f3a"
	pushTestRecipient    = "acct_SENTINEL_recipient_91c2"
	pushTestConversation = "conv_SENTINEL_conversation_4be8"
	pushTestSubscription = "psub_SENTINEL_subscription_c0d1"
	pushTestEndpoint     = "https://push.invalid/SENTINEL_endpoint_5e6f"
	pushTestPublicKey    = "SENTINEL_public_key_a1b2"
	pushTestAuthSecret   = "SENTINEL_auth_secret_d3e4"
	pushTimeLayout       = "2006-01-02T15:04:05.000000000Z"
)

type fakePushProvider struct {
	send func(context.Context, push.Notification) error

	mu    sync.Mutex
	calls []push.Notification
}

func (p *fakePushProvider) SendEncryptedEventAvailable(ctx context.Context, notification push.Notification) error {
	p.mu.Lock()
	p.calls = append(p.calls, notification)
	p.mu.Unlock()
	if p.send == nil {
		return nil
	}
	return p.send(ctx, notification)
}

func (p *fakePushProvider) callCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.calls)
}

type pushHarness struct {
	app      *App
	db       *sql.DB
	logs     *bytes.Buffer
	provider *fakePushProvider
}

func newPushHarness(t *testing.T, send func(context.Context, push.Notification) error) *pushHarness {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	path := filepath.Join(dir, "push.db")
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
	// A second handle seeds rows and installs fault-injection triggers
	// without widening the production store interface.
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatalf("open raw db: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	logs := &bytes.Buffer{}
	provider := &fakePushProvider{send: send}
	return &pushHarness{
		app: &App{
			Store:   store,
			Push:    provider,
			Log:     slog.New(slog.NewTextHandler(logs, nil)),
			metrics: newHTTPMetrics(),
		},
		db:       db,
		logs:     logs,
		provider: provider,
	}
}

// seed inserts one recipient subscription and count due wake jobs for it.
func (h *pushHarness) seed(t *testing.T, count int) {
	t.Helper()
	now := time.Now().UTC()
	created := now.Format(pushTimeLayout)
	due := now.Add(-time.Second).Format(pushTimeLayout)
	expires := now.Add(time.Hour).Format(pushTimeLayout)
	h.exec(t, `INSERT INTO accounts(id, username, password_hash, role, created_at) VALUES (?, 'sender', 'x', 'member', ?), (?, 'recipient', 'x', 'member', ?)`,
		pushTestSender, created, pushTestRecipient, created)
	h.exec(t, `INSERT INTO conversations(id, kind, created_by, created_at) VALUES (?, 'group', ?, ?)`,
		pushTestConversation, pushTestSender, created)
	h.exec(t, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES ('mem_a', ?, ?, 'member', ?), ('mem_b', ?, ?, 'member', ?)`,
		pushTestSender, pushTestConversation, created, pushTestRecipient, pushTestConversation, created)
	h.exec(t, `INSERT INTO push_subscriptions(id, account_id, provider, endpoint, public_key, auth_secret, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		pushTestSubscription, pushTestRecipient, pushTestProvider, pushTestEndpoint, pushTestPublicKey, pushTestAuthSecret, created)
	for i := 0; i < count; i++ {
		result, err := h.db.Exec(`INSERT INTO sync_events(event_type, conversation_id, payload_json, created_at) VALUES ('message.created', ?, '{}', ?)`,
			pushTestConversation, created)
		if err != nil {
			t.Fatalf("seed sync event: %v", err)
		}
		eventID, err := result.LastInsertId()
		if err != nil {
			t.Fatalf("seed sync event id: %v", err)
		}
		h.exec(t, `INSERT INTO push_wake_jobs(sync_event_id, conversation_id, sender_account_id, recipient_account_id, subscription_id, created_at, next_attempt_at, expires_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			eventID, pushTestConversation, pushTestSender, pushTestRecipient, pushTestSubscription, created, due, expires)
	}
}

func (h *pushHarness) exec(t *testing.T, query string, args ...any) {
	t.Helper()
	if _, err := h.db.Exec(query, args...); err != nil {
		t.Fatalf("exec %q: %v", query, err)
	}
}

type pushJobRow struct {
	attempts    int
	leased      bool
	nextAttempt time.Time
}

func (h *pushHarness) jobs(t *testing.T) []pushJobRow {
	t.Helper()
	rows, err := h.db.Query(`SELECT attempts, lease_token IS NOT NULL, next_attempt_at FROM push_wake_jobs ORDER BY sync_event_id`)
	if err != nil {
		t.Fatalf("read jobs: %v", err)
	}
	defer rows.Close()
	var jobs []pushJobRow
	for rows.Next() {
		var row pushJobRow
		var next string
		if err := rows.Scan(&row.attempts, &row.leased, &next); err != nil {
			t.Fatalf("scan job: %v", err)
		}
		if row.nextAttempt, err = time.Parse(pushTimeLayout, next); err != nil {
			t.Fatalf("parse next attempt: %v", err)
		}
		jobs = append(jobs, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate jobs: %v", err)
	}
	return jobs
}

func (h *pushHarness) subscriptionDisabled(t *testing.T) bool {
	t.Helper()
	var disabled bool
	if err := h.db.QueryRow(`SELECT disabled_at IS NOT NULL FROM push_subscriptions WHERE id = ?`, pushTestSubscription).Scan(&disabled); err != nil {
		t.Fatalf("read subscription: %v", err)
	}
	return disabled
}

type pushCounts struct{ attempted, delivered, failed, abandoned, backlog int64 }

func (h *pushHarness) counts() pushCounts {
	metric := h.app.metrics.push[pushTestProvider]
	return pushCounts{
		attempted: metric.attempted.Load(),
		delivered: metric.delivered.Load(),
		failed:    metric.failed.Load(),
		abandoned: metric.abandoned.Load(),
		backlog:   metric.backlog.Load(),
	}
}

func (h *pushHarness) assertCounts(t *testing.T, want pushCounts) {
	t.Helper()
	if got := h.counts(); got != want {
		t.Fatalf("push counters = %+v, want %+v", got, want)
	}
}

// assertPrivate checks logs and the rendered metrics for seeded identifiers
// and secrets. Call it only after the worker has returned.
func (h *pushHarness) assertPrivate(t *testing.T) {
	t.Helper()
	if strings.Contains(h.logs.String(), pushSentinel) {
		t.Fatalf("push identifier or secret appeared in logs: %s", h.logs.String())
	}
	recorder := httptest.NewRecorder()
	h.app.metrics.handle(recorder, httptest.NewRequest("GET", "/metrics", nil))
	body := recorder.Body.String()
	if strings.Contains(body, pushSentinel) {
		t.Fatalf("push identifier or secret appeared in metrics: %s", body)
	}
	if !strings.Contains(body, `veritra_push_deliveries_total{provider="fcm",result="attempted"}`) {
		t.Fatalf("push metrics missing from output: %s", body)
	}
}

func TestPushWakeSuccessCompletesJob(t *testing.T) {
	h := newPushHarness(t, nil)
	h.seed(t, 1)
	if !h.app.drainPushWakeBatch(context.Background(), pushTestProvider) {
		t.Fatal("drain reported no work")
	}
	if jobs := h.jobs(t); len(jobs) != 0 {
		t.Fatalf("delivered job still queued: %+v", jobs)
	}
	h.provider.mu.Lock()
	sent := h.provider.calls[0]
	h.provider.mu.Unlock()
	if sent.Provider != pushTestProvider || sent.Endpoint != pushTestEndpoint || sent.PublicKey != pushTestPublicKey || sent.AuthSecret != pushTestAuthSecret {
		t.Fatalf("provider received unexpected target: %+v", sent)
	}
	h.assertCounts(t, pushCounts{attempted: 1, delivered: 1})
	h.assertPrivate(t)
}

func TestPushWakeGoneOrInvalidTargetRetiresSubscription(t *testing.T) {
	for _, target := range []error{push.ErrSubscriptionGone, push.ErrInvalidTarget} {
		t.Run(target.Error(), func(t *testing.T) {
			h := newPushHarness(t, func(context.Context, push.Notification) error {
				return fmt.Errorf("provider said %s: %w", pushTestEndpoint, target)
			})
			h.seed(t, 1)
			h.app.drainPushWakeBatch(context.Background(), pushTestProvider)
			if !h.subscriptionDisabled(t) {
				t.Fatal("dead provider target was not disabled")
			}
			if jobs := h.jobs(t); len(jobs) != 0 {
				t.Fatalf("jobs for retired subscription remain: %+v", jobs)
			}
			h.assertCounts(t, pushCounts{attempted: 1, abandoned: 1})
			h.assertPrivate(t)
		})
	}
}

func TestPushWakeTransientFailureSchedulesRetry(t *testing.T) {
	// The provider error echoes the endpoint; the worker must not log it.
	h := newPushHarness(t, func(context.Context, push.Notification) error {
		return fmt.Errorf("upstream 503 for %s", pushTestEndpoint)
	})
	h.seed(t, 1)
	before := time.Now().UTC()
	h.app.drainPushWakeBatch(context.Background(), pushTestProvider)
	after := time.Now().UTC()
	jobs := h.jobs(t)
	if len(jobs) != 1 || jobs[0].attempts != 1 || jobs[0].leased {
		t.Fatalf("transient failure did not release job for retry: %+v", jobs)
	}
	// First retry waits 5s plus at most 20% jitter.
	if jobs[0].nextAttempt.Before(before.Add(5*time.Second)) || jobs[0].nextAttempt.After(after.Add(6*time.Second)) {
		t.Fatalf("next attempt %v outside [%v, %v]", jobs[0].nextAttempt, before.Add(5*time.Second), after.Add(6*time.Second))
	}
	h.assertCounts(t, pushCounts{attempted: 1, failed: 1, backlog: 1})
	h.assertPrivate(t)

	// The retry is not claimable early.
	claimed, _, err := h.app.Store.ClaimPushWakeJobs(context.Background(), pushTestProvider, 10, time.Now().UTC(), pushWakeLease)
	if err != nil || len(claimed) != 0 {
		t.Fatalf("retry claimable before backoff: jobs=%d err=%v", len(claimed), err)
	}
}

func TestPushWakeSendTimeoutSchedulesRetry(t *testing.T) {
	var deadlineOK atomic.Bool
	h := newPushHarness(t, func(ctx context.Context, _ push.Notification) error {
		deadline, ok := ctx.Deadline()
		deadlineOK.Store(ok && time.Until(deadline) <= pushWakeSendTimeout)
		return context.DeadlineExceeded
	})
	h.seed(t, 1)
	h.app.drainPushWakeBatch(context.Background(), pushTestProvider)
	if !deadlineOK.Load() {
		t.Fatal("provider send was not bounded by the send timeout")
	}
	jobs := h.jobs(t)
	if len(jobs) != 1 || jobs[0].attempts != 1 || jobs[0].leased || !jobs[0].nextAttempt.After(time.Now().UTC()) {
		t.Fatalf("timed out send was not scheduled for retry: %+v", jobs)
	}
	h.assertCounts(t, pushCounts{attempted: 1, failed: 1, backlog: 1})
	h.assertPrivate(t)
}

func TestPushWakeCancellationLeavesJobForLeaseExpiry(t *testing.T) {
	started := make(chan struct{})
	h := newPushHarness(t, func(ctx context.Context, _ push.Notification) error {
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	h.seed(t, 1)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.app.drainPushWakeBatch(ctx, pushTestProvider)
	}()
	<-started
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("worker did not stop after cancellation")
	}
	jobs := h.jobs(t)
	if len(jobs) != 1 || jobs[0].attempts != 1 || !jobs[0].leased {
		t.Fatalf("cancelled send changed durable job state: %+v", jobs)
	}
	counts := h.counts()
	if counts.attempted != 1 || counts.failed != 0 || counts.delivered != 0 || counts.abandoned != 0 {
		t.Fatalf("cancelled send counted as an outcome: %+v", counts)
	}
	h.assertPrivate(t)

	claimed, _, err := h.app.Store.ClaimPushWakeJobs(context.Background(), pushTestProvider, 10, time.Now().UTC(), pushWakeLease)
	if err != nil || len(claimed) != 0 {
		t.Fatalf("leased job claimable before lease expiry: jobs=%d err=%v", len(claimed), err)
	}
	claimed, _, err = h.app.Store.ClaimPushWakeJobs(context.Background(), pushTestProvider, 10, time.Now().UTC().Add(pushWakeLease+time.Second), pushWakeLease)
	if err != nil || len(claimed) != 1 || claimed[0].Attempts != 2 {
		t.Fatalf("job not reclaimable after lease expiry: jobs=%+v err=%v", claimed, err)
	}
}

func TestPushWakeMissingSubscriptionDropsJob(t *testing.T) {
	h := newPushHarness(t, nil)
	h.seed(t, 1)
	ctx := context.Background()
	claimed, _, err := h.app.Store.ClaimPushWakeJobs(ctx, pushTestProvider, 10, time.Now().UTC(), pushWakeLease)
	if err != nil || len(claimed) != 1 {
		t.Fatalf("claim: jobs=%d err=%v", len(claimed), err)
	}
	// The subscription is disabled between claim and send.
	h.exec(t, `UPDATE push_subscriptions SET disabled_at = ? WHERE id = ?`, time.Now().UTC().Format(pushTimeLayout), pushTestSubscription)
	h.app.deliverPushWake(ctx, h.app.metrics.push[pushTestProvider], claimed[0])
	if calls := h.provider.callCount(); calls != 0 {
		t.Fatalf("provider called %d times for a missing subscription", calls)
	}
	if jobs := h.jobs(t); len(jobs) != 0 {
		t.Fatalf("job for missing subscription remains: %+v", jobs)
	}
	h.assertCounts(t, pushCounts{abandoned: 1})
	h.assertPrivate(t)
}

func TestPushWakeStoreWriteFailuresAreLoggedAndCounted(t *testing.T) {
	for _, tc := range []struct {
		name         string
		trigger      string
		sendErr      error
		event        string
		want         pushCounts
		wantDisabled bool
	}{
		{
			name:    "completion",
			trigger: `CREATE TRIGGER inject_failure BEFORE DELETE ON push_wake_jobs BEGIN SELECT RAISE(ABORT, 'injected'); END`,
			event:   "push_wake_completion_failed",
			want:    pushCounts{attempted: 1, failed: 1, backlog: 1},
		},
		{
			name:    "retry",
			trigger: `CREATE TRIGGER inject_failure BEFORE UPDATE ON push_wake_jobs WHEN NEW.lease_token IS NULL BEGIN SELECT RAISE(ABORT, 'injected'); END`,
			sendErr: errors.New("upstream 503"),
			event:   "push_wake_retry_record_failed",
			want:    pushCounts{attempted: 1, failed: 1, backlog: 1},
		},
		{
			name:    "retire",
			trigger: `CREATE TRIGGER inject_failure BEFORE UPDATE ON push_subscriptions BEGIN SELECT RAISE(ABORT, 'injected'); END`,
			sendErr: push.ErrSubscriptionGone,
			event:   "push_wake_retire_failed",
			want:    pushCounts{attempted: 1, abandoned: 1, backlog: 1},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newPushHarness(t, func(context.Context, push.Notification) error { return tc.sendErr })
			h.seed(t, 1)
			h.exec(t, tc.trigger)
			h.app.drainPushWakeBatch(context.Background(), pushTestProvider)
			if !strings.Contains(h.logs.String(), "msg="+tc.event+" provider=fcm") {
				t.Fatalf("missing %s log: %s", tc.event, h.logs.String())
			}
			// The failed write leaves the claimed lease in place, so the job
			// is redelivered after lease expiry rather than lost.
			jobs := h.jobs(t)
			if len(jobs) != 1 || jobs[0].attempts != 1 || !jobs[0].leased {
				t.Fatalf("failed store write changed durable job state: %+v", jobs)
			}
			if h.subscriptionDisabled(t) != tc.wantDisabled {
				t.Fatalf("subscription disabled = %v, want %v", !tc.wantDisabled, tc.wantDisabled)
			}
			h.assertCounts(t, tc.want)
			h.assertPrivate(t)
		})
	}
}

func TestPushWakeDeliveryConcurrencyIsBounded(t *testing.T) {
	var inFlight, peak atomic.Int64
	release := make(chan struct{})
	h := newPushHarness(t, func(context.Context, push.Notification) error {
		current := inFlight.Add(1)
		for {
			seen := peak.Load()
			if current <= seen || peak.CompareAndSwap(seen, current) {
				break
			}
		}
		<-release
		inFlight.Add(-1)
		return nil
	})
	total := 3 * pushWakeConcurrency
	h.seed(t, total)
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.app.drainPushWakeBatch(context.Background(), pushTestProvider)
	}()
	deadline := time.Now().Add(5 * time.Second)
	for inFlight.Load() < pushWakeConcurrency {
		if time.Now().After(deadline) {
			close(release)
			t.Fatalf("only %d concurrent sends started, want %d", inFlight.Load(), pushWakeConcurrency)
		}
		time.Sleep(time.Millisecond)
	}
	// Give any excess worker a chance to show up before releasing the gate.
	time.Sleep(50 * time.Millisecond)
	close(release)
	<-done
	if got := peak.Load(); got != pushWakeConcurrency {
		t.Fatalf("peak concurrent sends = %d, want %d", got, pushWakeConcurrency)
	}
	if jobs := h.jobs(t); len(jobs) != 0 {
		t.Fatalf("%d jobs remain after bounded drain", len(jobs))
	}
	h.assertCounts(t, pushCounts{attempted: int64(total), delivered: int64(total)})
	h.assertPrivate(t)
}
