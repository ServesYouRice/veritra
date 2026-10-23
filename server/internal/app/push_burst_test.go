package app

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"private-messenger/server/internal/push"
)

// Card I36: a 100-target burst stays within the worker and socket bounds.
// One pass claims at most pushWakeBatchSize jobs and never has more than
// pushWakeConcurrency provider sends open; the rest stay durable for the
// next pass.
func TestPushWakeHundredTargetBurstStaysWithinBounds(t *testing.T) {
	const burst = 100
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
	h.seed(t, burst)

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
	time.Sleep(50 * time.Millisecond)
	close(release)
	<-done

	if got := peak.Load(); got != pushWakeConcurrency {
		t.Fatalf("peak concurrent sends = %d, want %d", got, pushWakeConcurrency)
	}
	if got := h.provider.callCount(); got != pushWakeBatchSize {
		t.Fatalf("first pass sent %d wakes, want the %d-job batch bound", got, pushWakeBatchSize)
	}
	remaining := h.jobs(t)
	if len(remaining) != burst-pushWakeBatchSize {
		t.Fatalf("%d jobs remain after the first pass, want %d", len(remaining), burst-pushWakeBatchSize)
	}
	for _, job := range remaining {
		if job.leased || job.attempts != 0 {
			t.Fatalf("job outside the batch was touched: %+v", job)
		}
	}

	h.app.drainPushWakeBatch(context.Background(), pushTestProvider)
	if jobs := h.jobs(t); len(jobs) != 0 {
		t.Fatalf("%d jobs remain after the second pass", len(jobs))
	}
	if got := peak.Load(); got != pushWakeConcurrency {
		t.Fatalf("peak concurrent sends after both passes = %d, want %d", got, pushWakeConcurrency)
	}
	h.assertCounts(t, pushCounts{attempted: burst, delivered: burst})
	h.assertPrivate(t)
}
