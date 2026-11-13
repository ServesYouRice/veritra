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
	go func() { w.runCatchUp(ctx, w.devices[0], clientSlot{}, wakeUp, nil, nil); close(done) }()

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

// TestCatchUpObservesDeliveries: the realtime frame names no message, so a
// delivery and its downloads come from the sync page. A message from
// another device is one delivery and one download per attachment; the
// device's own message is neither; a cold sync that re-reads the same
// events counts nothing again.
func TestCatchUpObservesDeliveries(t *testing.T) {
	const events = `{"events":[` +
		`{"id":6,"type":"message.envelope.created","payload":{"envelope":{"sender_device_id":"d1","idempotency_key":"k-other","attachment_refs":["att-1"]}}},` +
		`{"id":7,"type":"message.envelope.created","payload":{"envelope":{"sender_device_id":"d0","idempotency_key":"k-own","attachment_refs":["att-2"]}}},` +
		`{"id":8,"type":"reaction.created","payload":{}}` +
		`],"latest_event_id":8}`
	var pages atomic.Int64
	w := testWorld(t, http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		switch r.URL.RawQuery {
		case "after=0&limit=1":
			_, _ = rw.Write([]byte(`{"events":[],"latest_event_id":5}`))
		case "after=5&limit=200", "after=4&limit=200":
			pages.Add(1)
			_, _ = rw.Write([]byte(events))
		default:
			_, _ = rw.Write([]byte(`{"events":[],"latest_event_id":8}`))
		}
	}))
	other := clientSlot{dev: 0}
	w.deliveries.start("k-other", time.Now(), []clientSlot{other})
	w.deliveries.sent("k-other", true)
	w.deliveries.start("k-own", time.Now(), []clientSlot{other})
	w.deliveries.sent("k-own", true)
	queue := make(chan download, 8)
	wakeUp, cold := make(chan struct{}, 1), make(chan struct{}, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { w.runCatchUp(ctx, w.devices[0], other, wakeUp, cold, queue); close(done) }()

	wake(wakeUp)
	waitFor(t, "the delivery from sync", func() bool { return countSamples(w.rec, opDelivery, outcomeOK) == 1 })
	wake(cold)
	waitFor(t, "the cold re-read", func() bool { return pages.Load() == 2 })
	waitFor(t, "the cold sync to finish", func() bool { return countSamples(w.rec, opColdSync) >= 2 })
	cancel()
	<-done
	if len(queue) != 1 {
		t.Fatalf("%d downloads queued, want 1 (the other device's attachment, once)", len(queue))
	}
	if job := <-queue; job.id != "att-1" {
		t.Fatalf("queued %q, want att-1", job.id)
	}
	if n := countSamples(w.rec, opDelivery, outcomeOK); n != 1 {
		t.Fatalf("%d deliveries, want 1", n)
	}
	if w.deliveries.size() != 1 {
		t.Fatalf("%d sends still tracked, want 1 (the device's own message is never delivered to it)", w.deliveries.size())
	}
}
