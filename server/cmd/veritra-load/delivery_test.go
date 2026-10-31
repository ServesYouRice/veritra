package main

import (
	"context"
	"io"
	"testing"
	"time"
)

// fakeClock is a controllable clock for the delivery tracker.
type fakeClock struct{ now time.Time }

func (c *fakeClock) Now() time.Time { return c.now }

func newTestTracker() (*deliveryTracker, *recorder, *fakeClock) {
	rec := newRecorder()
	clock := &fakeClock{now: rec.started.Add(time.Second)}
	tracker := newDeliveryTracker(rec, 30*time.Second)
	tracker.now = clock.Now
	return tracker, rec, clock
}

var (
	alice = clientSlot{dev: 1, slot: 0}
	bob   = clientSlot{dev: 2, slot: 0}
	bob2  = clientSlot{dev: 2, slot: 1}
)

func TestDeliveryTrackerCompletes(t *testing.T) {
	tracker, rec, clock := newTestTracker()
	started := clock.now
	tracker.start("k1", started, []clientSlot{alice, bob})
	tracker.sent("k1", true)
	tracker.observe("k1", alice, started.Add(40*time.Millisecond))
	tracker.observe("k1", alice, started.Add(50*time.Millisecond)) // a repeat
	tracker.observe("k1", bob, started.Add(60*time.Millisecond))
	if n := countSamples(rec, opDelivery, outcomeOK); n != 2 || countSamples(rec, opDelivery) != 2 {
		t.Fatalf("%d OK of %d delivery samples, want 2 of 2", n, countSamples(rec, opDelivery))
	}
	if tracker.size() != 0 || rec.liveCount() != 0 {
		t.Fatalf("tracker %d, live %d after every delivery was seen", tracker.size(), rec.liveCount())
	}
}

func TestDeliveryTrackerForgetsFailedSends(t *testing.T) {
	tracker, rec, clock := newTestTracker()
	tracker.start("k1", clock.now, []clientSlot{alice, bob})
	tracker.observe("k1", alice, clock.now) // the server published, the response failed
	tracker.sent("k1", false)
	tracker.observe("k1", bob, clock.now)
	if tracker.size() != 0 || rec.liveCount() != 0 || countSamples(rec, opDelivery) != 0 {
		t.Fatalf("a failed send left %d entries, %d live handles, %d samples", tracker.size(), rec.liveCount(), countSamples(rec, opDelivery))
	}
	tracker.start("k2", clock.now, nil) // nobody online to deliver to
	tracker.sent("k2", true)
	if tracker.size() != 0 {
		t.Fatal("a send without recipients was kept")
	}
}

// TestDeliveryTrackerExpiresMissedDeliveries: of two expected recipients
// one sees the event; after the deadline the other is one missed record,
// attributed to the send's start, and a late or repeated event adds
// nothing.
func TestDeliveryTrackerExpiresMissedDeliveries(t *testing.T) {
	tracker, rec, clock := newTestTracker()
	started := clock.now
	tracker.start("k1", started, []clientSlot{alice, bob})
	tracker.sent("k1", true)
	tracker.observe("k1", alice, started.Add(20*time.Millisecond))
	tracker.expire(started) // not yet due
	if tracker.size() != 1 {
		t.Fatal("a delivery expired before its deadline")
	}
	clock.now = started.Add(31 * time.Second)
	tracker.expire(clock.now.Add(-tracker.deadline))
	tracker.observe("k1", bob, clock.now)
	tracker.observe("k1", alice, clock.now)
	if ok, missed := countSamples(rec, opDelivery, outcomeOK), countSamples(rec, opDelivery, outcomeMissed); ok != 1 || missed != 1 || countSamples(rec, opDelivery) != 2 {
		t.Fatalf("ok %d, missed %d, total %d; want 1, 1, 2", ok, missed, countSamples(rec, opDelivery))
	}
	if tracker.size() != 0 || rec.liveCount() != 0 {
		t.Fatalf("tracker %d, live %d after expiry", tracker.size(), rec.liveCount())
	}
	at := started.Sub(rec.started)
	ops, _ := rec.summarize(at, at+time.Millisecond)
	if d := ops[opDelivery]; d.Count != 2 || d.Errors != 1 {
		t.Fatalf("delivery summary at the send's start = %+v", d)
	}
}

// TestDeliveryTrackerKeepsEarlyEvents: a recipient can see the event before
// the sender gets its 201; that sighting counts once the send succeeds.
func TestDeliveryTrackerKeepsEarlyEvents(t *testing.T) {
	tracker, rec, clock := newTestTracker()
	started := clock.now
	tracker.start("k1", started, []clientSlot{alice, bob})
	tracker.observe("k1", bob, started.Add(15*time.Millisecond))
	tracker.observe("k1", bob, started.Add(25*time.Millisecond))
	tracker.observe("k1", clientSlot{dev: 9}, started) // not a recipient
	tracker.sent("k1", true)
	if n := countSamples(rec, opDelivery, outcomeOK); n != 1 {
		t.Fatalf("%d OK samples, want the early one", n)
	}
	rec.mu.Lock()
	latency := rec.samples[0].latency
	rec.mu.Unlock()
	if latency != 15*time.Millisecond {
		t.Fatalf("latency %s, want 15ms from the first sighting", latency)
	}
	if tracker.size() != 1 || rec.liveCount() != 1 {
		t.Fatalf("tracker %d, live %d; alice is still awaited", tracker.size(), rec.liveCount())
	}
	tracker.drain()
	if tracker.size() != 0 || rec.liveCount() != 0 || countSamples(rec, opDelivery) != 2 {
		t.Fatal("drain left work behind")
	}
}

// TestSettleWaitsForDeliveries: a step's summary waits for deliveries of
// sends started in its window until they are seen or expire.
func TestSettleWaitsForDeliveries(t *testing.T) {
	tracker, rec, clock := newTestTracker()
	started := time.Now()
	tracker.start("k1", started, []clientSlot{alice})
	tracker.sent("k1", true)
	to := time.Since(rec.started)
	done := settleAsync(rec, to, time.Minute)
	expectBlocked(t, done)
	clock.now = started.Add(time.Minute)
	tracker.expire(clock.now.Add(-tracker.deadline))
	<-done
	if n := countSamples(rec, opDelivery, outcomeMissed); n != 1 {
		t.Fatalf("%d missed samples, want 1", n)
	}
}

func TestDeliverySweepStopsWithTheLoad(t *testing.T) {
	tracker, _, _ := newTestTracker()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { tracker.sweep(ctx, time.Millisecond); close(done) }()
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("sweep ignored cancellation")
	}
}

// TestExpectedRecipients: every client of an online member except the
// sending device; offline members expect nothing.
func TestExpectedRecipients(t *testing.T) {
	devices := []*device{{index: 0, deviceID: "d0"}, {index: 1, deviceID: "d1"}, {index: 2, deviceID: "d2"}, {index: 3, deviceID: "d3"}}
	w := &world{devices: devices}
	companion := &device{index: 0, deviceID: "d0-companion"}
	// Device 0 has a separately linked companion, device 1 a second client
	// on the same device, device 2 one client, and device 3 is offline.
	w.clients = [][]*device{{devices[0], companion}, {devices[1], devices[1]}, {devices[2]}, nil}
	conv := conversation{members: []int{0, 1, 2, 3}}
	got := map[clientSlot]bool{}
	for _, c := range w.expectedRecipients(devices[0], conv) {
		got[c] = true
	}
	want := map[clientSlot]bool{{dev: 0, slot: 1}: true, {dev: 1, slot: 0}: true, {dev: 1, slot: 1}: true, {dev: 2, slot: 0}: true}
	if len(got) != len(want) {
		t.Fatalf("expected recipients %v, want %v", got, want)
	}
	for c := range want {
		if !got[c] {
			t.Fatalf("expected recipients %v, want %v", got, want)
		}
	}
	for _, c := range w.expectedRecipients(devices[1], conv) {
		if c.dev == 1 {
			t.Fatalf("the sending device's own clients were expected: %v", c)
		}
	}
}

func TestDeliveryDeadlineFlag(t *testing.T) {
	base := []string{"-target", "http://127.0.0.1:1", "-setup-token-file", "token"}
	opts, err := parseOptions(base, io.Discard)
	if err != nil || opts.DeliveryDeadline != defaultDeliveryDeadline {
		t.Fatalf("default deadline = %s, %v", opts.DeliveryDeadline, err)
	}
	for _, bad := range []string{"2s", "1s", settleGrace.String(), "1h"} {
		if _, err := parseOptions(append(base, "-delivery-deadline", bad), io.Discard); err == nil {
			t.Fatalf("-delivery-deadline %s accepted", bad)
		}
	}
	if opts, err := parseOptions(append(base, "-delivery-deadline", "10s"), io.Discard); err != nil || opts.DeliveryDeadline != 10*time.Second {
		t.Fatalf("10s = %s, %v", opts.DeliveryDeadline, err)
	}
}

// TestMissedDeliveriesRankInThePercentiles: 980 fast deliveries, 10 slow
// and 10 missed. Ranking only the seen ones puts the p99 at a fast one;
// with the missed ones ranked at their wait, the p99 is a slow one and the
// step misses the 2 s target although only 1% were missed.
func TestMissedDeliveriesRankInThePercentiles(t *testing.T) {
	r := newRecorder()
	add := func(n int, latency time.Duration, result outcome) {
		for i := 0; i < n; i++ {
			r.record(opDelivery, r.started.Add(time.Second), latency, result)
		}
	}
	add(980, 100*time.Millisecond, outcomeOK)
	add(10, 5*time.Second, outcomeOK)
	add(10, 31*time.Second, outcomeMissed)
	ops, _ := r.summarize(0, time.Minute)
	d := ops[opDelivery]
	if d.Count != 1000 || d.Errors != 10 || d.P99Ms < 2000 || d.MaxMs != 31000 {
		t.Fatalf("delivery summary = %+v", d)
	}
	if evaluateStep(stepResult{Ops: ops}).Pass {
		t.Fatal("a step whose true delivery p99 is 5 s passed")
	}
}

func TestMissedDeliveriesFailTheStep(t *testing.T) {
	step := stepResult{Ops: make([]opSummary, opCount)}
	step.Ops[opDelivery] = opSummary{Op: "realtime_delivery", Count: 100, Errors: 2, P99Ms: 40}
	if evaluateStep(step).Pass {
		t.Fatal("a step with 2% missed deliveries passed")
	}
	step.Ops[opDelivery].Errors = 1
	if !evaluateStep(step).Pass {
		t.Fatalf("1%% missed failed: %v", evaluateStep(step).Missed)
	}
}
