package main

import (
	"context"
	"io"
	"math"
	mrand "math/rand/v2"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
	"time"
)

// testWorld is a two-device world with one conversation against handler.
func testWorld(t *testing.T, handler http.Handler) *world {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	target, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	w := &world{
		client: newAPIClient(target, 32), base: target, profile: profile{CiphertextBytes: 16}, rec: newRecorder(),
		devices: []*device{
			{index: 0, token: "token-0", accountID: "a0", deviceID: "d0", ip: deviceIP(0)},
			{index: 1, token: "token-1", accountID: "a1", deviceID: "d1", ip: deviceIP(1)},
		},
		convs:    []conversation{{id: "c1", members: []int{0, 1}}},
		byDevice: [][]int{{0}, {0}},
	}
	w.clients = [][]*device{{w.devices[0]}, {w.devices[1]}}
	w.deliveries = newDeliveryTracker(w.rec, defaultDeliveryDeadline)
	return w
}

// countSamples counts op's samples, and those with one of results when any
// are given.
func countSamples(r *recorder, op int, results ...outcome) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, s := range r.samples {
		if int(s.op) != op {
			continue
		}
		if len(results) == 0 {
			n++
			continue
		}
		for _, result := range results {
			if s.result == result {
				n++
				break
			}
		}
	}
	return n
}

// TestOpenLoopSenderKeepsArrivingWhenTheServerStalls: a server that never
// answers a send must not slow the arrivals. A device keeps at most
// maxSendsInFlight sends open, and every arrival over that cap is recorded
// as a dropped send rather than skipped.
func TestOpenLoopSenderKeepsArrivingWhenTheServerStalls(t *testing.T) {
	var started atomic.Int64
	w := testWorld(t, http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/api/v1/messages/envelopes" {
			started.Add(1)
			// The server notices a cancelled request only once the body
			// has been read.
			_, _ = io.Copy(io.Discard, r.Body)
			<-r.Context().Done()
			return
		}
		rw.WriteHeader(http.StatusNotFound)
	}))
	w.rate.Store(math.Float64bits(600))
	ctx, cancel := context.WithTimeout(context.Background(), 2500*time.Millisecond)
	defer cancel()
	w.runSender(ctx, w.devices[0], mrand.New(mrand.NewPCG(5, 6)))

	sends := countSamples(w.rec, opSend)
	dropped := countSamples(w.rec, opSend, outcomeDropped)
	if sends < 3*maxSendsInFlight/2 {
		t.Fatalf("only %d send arrivals in 2.5 s at 10/s against a stalled server", sends)
	}
	if got := started.Load(); got != maxSendsInFlight {
		t.Fatalf("server saw %d sends in flight, want the cap %d", got, maxSendsInFlight)
	}
	if dropped != sends-maxSendsInFlight {
		t.Fatalf("dropped = %d of %d arrivals, want %d", dropped, sends, sends-maxSendsInFlight)
	}
	if arrivals := w.arrivals.Load(); arrivals != int64(sends) {
		t.Fatalf("arrivals = %d, send samples = %d; every arrival needs one record", arrivals, sends)
	}
}

// TestOpenLoopSenderIgnoresLatency: with a slow server the arrivals still
// follow the configured rate rather than the server's pace.
func TestOpenLoopSenderIgnoresLatency(t *testing.T) {
	w := testWorld(t, http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case <-time.After(400 * time.Millisecond):
		case <-r.Context().Done():
			return
		}
		rw.WriteHeader(http.StatusCreated)
		_, _ = rw.Write([]byte(`{"id":"m"}`))
	}))
	w.rate.Store(math.Float64bits(600))
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	w.runSender(ctx, w.devices[0], mrand.New(mrand.NewPCG(7, 8)))
	// A closed loop manages at most 5 sends in 2 s; 10/s offers about 20.
	if sends := countSamples(w.rec, opSend); sends < 10 {
		t.Fatalf("%d send attempts in 2 s at 10/s with 400 ms latency", sends)
	}
	if ok := countSamples(w.rec, opSend, outcomeOK); ok < 8 {
		t.Fatalf("only %d sends completed", ok)
	}
}

// TestNextGapIsUntruncatedExponential: at 0.1 messages a minute the mean gap
// is 10 minutes, and gaps longer than the old 2-minute cap occur.
func TestNextGapIsUntruncatedExponential(t *testing.T) {
	rng := mrand.New(mrand.NewPCG(47, 1))
	const n = 200_000
	var sum time.Duration
	long := 0
	for i := 0; i < n; i++ {
		gap := nextGap(rng, 0.1)
		if gap < 0 {
			t.Fatalf("negative gap %s", gap)
		}
		sum += gap
		if gap > 2*time.Minute {
			long++
		}
	}
	mean := sum.Minutes() / n
	// The standard error is 10/sqrt(n), about 0.022 minutes; 2% is ~9 of
	// them. A 2-minute cap would give a mean of about 1.8 minutes.
	if math.Abs(mean-10) > 0.2 {
		t.Fatalf("mean gap %.3f min, want 10 ± 0.2", mean)
	}
	if long < n/2 {
		t.Fatalf("%d of %d gaps over 2 min; about 82%% expected", long, n)
	}
	if gap := nextGap(rng, 1e-300); gap <= 0 {
		t.Fatalf("a vanishing rate gave gap %s", gap)
	}
}

// TestSenderAppliesRateChangePromptly: a device waiting out a very long gap
// redraws it when the rate changes, so a step's rate applies within about a
// second without truncating any gap.
func TestSenderAppliesRateChangePromptly(t *testing.T) {
	w := testWorld(t, http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		rw.WriteHeader(http.StatusCreated)
		_, _ = rw.Write([]byte(`{"id":"m"}`))
	}))
	w.rate.Store(math.Float64bits(0.0001))
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	go func() {
		time.Sleep(300 * time.Millisecond)
		w.rate.Store(math.Float64bits(600))
	}()
	w.runSender(ctx, w.devices[0], mrand.New(mrand.NewPCG(9, 10)))
	if sends := countSamples(w.rec, opSend); sends < 5 {
		t.Fatalf("%d sends after raising the rate to 10/s", sends)
	}
}

func TestSenderPausesAtRateZero(t *testing.T) {
	w := testWorld(t, http.NotFoundHandler())
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	w.runSender(ctx, w.devices[0], mrand.New(mrand.NewPCG(1, 2)))
	if sends := countSamples(w.rec, opSend); sends != 0 || w.arrivals.Load() != 0 {
		t.Fatalf("%d sends at rate 0", sends)
	}
}
