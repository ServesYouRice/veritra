package app

import (
	"bytes"
	"context"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/push"
	"private-messenger/server/internal/storage"
)

// Capacity contract scenarios (card I47, docs/operations.md "Capacity
// contract"): a stalled push provider and a restart with wake work in
// flight must lose nothing and recover on their own. The provider deadline
// and retry delay are shortened from 10 s and 5 s so the scenarios run in
// seconds; the bounds they check scale with those two values.

func trackPeak(inFlight, peak *atomic.Int64) func() {
	current := inFlight.Add(1)
	for {
		seen := peak.Load()
		if current <= seen || peak.CompareAndSwap(seen, current) {
			break
		}
	}
	return func() { inFlight.Add(-1) }
}

func waitFor(t *testing.T, limit time.Duration, ok func() bool) time.Duration {
	t.Helper()
	started := time.Now()
	for !ok() {
		if time.Since(started) > limit {
			t.Fatalf("condition not met within %s", limit)
		}
		time.Sleep(10 * time.Millisecond)
	}
	return time.Since(started)
}

func TestScenarioProviderStallKeepsWorkAndDrainsAfterRecovery(t *testing.T) {
	var stalled atomic.Bool
	stalled.Store(true)
	var inFlight, peak atomic.Int64
	h := newPushHarness(t, func(ctx context.Context, _ push.Notification) error {
		defer trackPeak(&inFlight, &peak)()
		if stalled.Load() {
			<-ctx.Done()
			return ctx.Err()
		}
		return nil
	})
	h.app.pushSendTimeout = 50 * time.Millisecond
	h.app.pushRetryDelay = 100 * time.Millisecond
	const jobs = 200
	h.seed(t, jobs)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.app.runPushWakeProvider(ctx, pushTestProvider)
	}()
	defer func() { cancel(); <-done }()

	metric := h.app.metrics.push[pushTestProvider]
	// The backlog gauges refresh after each claimed batch (64 jobs).
	waitFor(t, 10*time.Second, func() bool { return metric.timeouts.Load() >= pushWakeBatchSize && metric.backlog.Load() == jobs })
	if delivered := metric.delivered.Load(); delivered != 0 {
		t.Fatalf("%d wakes delivered by a stalled provider", delivered)
	}
	if remaining := len(h.jobs(t)); remaining != jobs {
		t.Fatalf("%d of %d wake jobs left during the stall", remaining, jobs)
	}
	if metric.backlog.Load() != jobs || metric.oldestQueuedAt.Load() == 0 {
		t.Fatalf("stall not visible: backlog=%d oldest=%d", metric.backlog.Load(), metric.oldestQueuedAt.Load())
	}

	stalled.Store(false)
	// Recovery bound: one retry delay plus the batches needed at 64 jobs and
	// 8 sends each; generous for a shared test host.
	drained := waitFor(t, 15*time.Second, func() bool { return len(h.jobs(t)) == 0 })
	t.Logf("drained %d jobs %s after the provider recovered", jobs, drained.Round(time.Millisecond))
	waitFor(t, 5*time.Second, func() bool { return metric.backlog.Load() == 0 && metric.oldestQueuedAt.Load() == 0 })
	if peak.Load() > pushWakeConcurrency {
		t.Fatalf("peak concurrent sends = %d, bound is %d", peak.Load(), pushWakeConcurrency)
	}
	if metric.delivered.Load() < jobs || metric.abandoned.Load() != 0 {
		t.Fatalf("delivered=%d abandoned=%d, want every job delivered and none dropped", metric.delivered.Load(), metric.abandoned.Load())
	}
	cancel()
	<-done
	h.assertPrivate(t)
}

func TestScenarioRestartResumesLeasedWakeWork(t *testing.T) {
	var inFlight, peak atomic.Int64
	h := newPushHarness(t, func(ctx context.Context, _ push.Notification) error {
		defer trackPeak(&inFlight, &peak)()
		<-ctx.Done()
		return ctx.Err()
	})
	const jobs = 100
	h.seed(t, jobs)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.app.runPushWakeProvider(ctx, pushTestProvider)
	}()
	waitFor(t, 5*time.Second, func() bool { return inFlight.Load() == pushWakeConcurrency })
	// Stop as a restart does: the batch's leases stay in the database.
	cancel()
	<-done
	leased := 0
	for _, job := range h.jobs(t) {
		if job.leased {
			leased++
		}
	}
	if remaining := len(h.jobs(t)); remaining != jobs || leased == 0 {
		t.Fatalf("after stop: %d jobs, %d leased; want all %d kept and some leased", remaining, leased, jobs)
	}

	// A new process opens the same database.
	var path string
	if err := h.db.QueryRow(`SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&path); err != nil {
		t.Fatal(err)
	}
	store, err := storage.Open(context.Background(), config.Config{DatabasePath: path})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	provider := &fakePushProvider{}
	restarted := &App{Store: store, Push: provider, Log: slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)), metrics: newHTTPMetrics()}
	restartCtx, restartCancel := context.WithCancel(context.Background())
	restartDone := make(chan struct{})
	go func() {
		defer close(restartDone)
		restarted.runPushWakeProvider(restartCtx, pushTestProvider)
	}()
	defer func() { restartCancel(); <-restartDone }()
	// Jobs that were not leased are sent at once; leased ones wait out their
	// 30 s lease, so nothing is sent twice while the old send may still run.
	waitFor(t, 10*time.Second, func() bool { return len(h.jobs(t)) == leased })
	if sent := provider.callCount(); sent != jobs-leased {
		t.Fatalf("restarted worker sent %d wakes before the leases expired, want %d", sent, jobs-leased)
	}
	// Let the 30 s lease pass.
	h.exec(t, `UPDATE push_wake_jobs SET lease_expires_at = ?`, time.Now().UTC().Add(-time.Second).Format(pushTimeLayout))
	waitFor(t, 10*time.Second, func() bool { return len(h.jobs(t)) == 0 })
	if delivered := restarted.metrics.push[pushTestProvider].delivered.Load(); delivered != jobs {
		t.Fatalf("delivered %d wakes after restart, want %d", delivered, jobs)
	}
}
