package main

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestInitialSyncFailureIsRecorded: the catch-up's first request, which
// sets the cursor, is a measured sync like the pages after it.
func TestInitialSyncFailureIsRecorded(t *testing.T) {
	var failing atomic.Bool
	failing.Store(true)
	var initial, paged atomic.Int64
	w := testWorld(t, http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		switch r.URL.RawQuery {
		case "after=0&limit=1":
			initial.Add(1)
			if failing.Load() {
				rw.WriteHeader(http.StatusInternalServerError)
				return
			}
			_, _ = rw.Write([]byte(`{"events":[],"latest_event_id":5}`))
		case "after=5&limit=200":
			paged.Add(1)
			_, _ = rw.Write([]byte(`{"events":[],"latest_event_id":5}`))
		default:
			rw.WriteHeader(http.StatusBadRequest)
		}
	}))
	wakeUp := make(chan struct{}, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { w.runCatchUp(ctx, w.devices[0], wakeUp, nil); close(done) }()

	wake(wakeUp)
	waitFor(t, "the failed initial sync to be recorded", func() bool { return countSamples(w.rec, opSync) == 1 })
	if n := countSamples(w.rec, opSync, outcomeServerError); n != 1 {
		t.Fatalf("%d failed sync samples, want 1", n)
	}
	if paged.Load() != 0 {
		t.Fatal("paged without a cursor")
	}

	failing.Store(false)
	wake(wakeUp)
	waitFor(t, "the cursor to be used", func() bool { return paged.Load() == 1 })
	waitFor(t, "both syncs of the second wake-up", func() bool { return countSamples(w.rec, opSync) == 3 })
	cancel()
	<-done
	if initial.Load() != 2 || countSamples(w.rec, opSync, outcomeOK) != 2 || countSamples(w.rec, opSync) != 3 {
		t.Fatalf("initial requests %d, sync samples %d (%d OK); want 2, 3 (2 OK)",
			initial.Load(), countSamples(w.rec, opSync), countSamples(w.rec, opSync, outcomeOK))
	}
}
