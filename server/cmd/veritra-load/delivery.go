package main

import (
	"context"
	"sync"
	"time"
)

// clientSlot names one simulated app instance: an online device's primary
// client (slot 0) or its companion (slot 1).
type clientSlot struct{ dev, slot int }

// deliveryTracker measures realtime delivery per (message, recipient
// client). A send registers the clients that should see its event before
// the request goes out; once the server acknowledges it, each expected
// delivery becomes a recorder handle that starts at the send's start and
// ends exactly once: OK when the client sees the event, missed when the
// deadline passes first. A failed send expects nothing. Entries are deleted
// when their last delivery ends, so memory follows outstanding work, not
// the number of sends.
type deliveryTracker struct {
	rec      *recorder
	deadline time.Duration
	now      func() time.Time
	mu       sync.Mutex
	sends    map[string]*trackedSend // by idempotency key
}

type trackedSend struct {
	started  time.Time
	expected map[clientSlot]bool
	acked    bool
	// early holds events seen before the send's response arrived.
	early map[clientSlot]time.Time
	// handles are the deliveries still awaited after the response.
	handles map[clientSlot]*inflight
}

func newDeliveryTracker(rec *recorder, deadline time.Duration) *deliveryTracker {
	return &deliveryTracker{rec: rec, deadline: deadline, now: time.Now, sends: map[string]*trackedSend{}}
}

// start registers a send about to be issued. Call it before the request,
// because a recipient can see the event before the sender sees the 201.
func (t *deliveryTracker) start(key string, started time.Time, expected []clientSlot) {
	if len(expected) == 0 {
		return
	}
	set := make(map[clientSlot]bool, len(expected))
	for _, c := range expected {
		set[c] = true
	}
	t.mu.Lock()
	t.sends[key] = &trackedSend{started: started, expected: set}
	t.mu.Unlock()
}

// sent settles the send's outcome. Call it before the send's own recorder
// handle ends, so a step's settle never sees the window's work as done
// while its deliveries are not registered yet.
func (t *deliveryTracker) sent(key string, ok bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	send := t.sends[key]
	if send == nil {
		return
	}
	if !ok {
		delete(t.sends, key)
		return
	}
	send.acked = true
	send.handles = make(map[clientSlot]*inflight, len(send.expected))
	for c := range send.expected {
		h := t.rec.begin(opDelivery, send.started)
		if seen, ok := send.early[c]; ok {
			t.rec.end(h, outcomeOK, seen.Sub(send.started))
			continue
		}
		send.handles[c] = h
	}
	send.early = nil
	if len(send.handles) == 0 {
		delete(t.sends, key)
	}
}

// observe records that client c saw the send's event at at. Only the first
// sighting of an expected delivery counts; repeats, unexpected clients and
// unknown keys (seeding, failed or finished sends) record nothing.
func (t *deliveryTracker) observe(key string, c clientSlot, at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	send := t.sends[key]
	if send == nil || !send.expected[c] {
		return
	}
	if !send.acked {
		if send.early == nil {
			send.early = map[clientSlot]time.Time{}
		}
		if _, seen := send.early[c]; !seen {
			send.early[c] = at
		}
		return
	}
	h := send.handles[c]
	if h == nil {
		return
	}
	delete(send.handles, c)
	t.rec.end(h, outcomeOK, at.Sub(send.started))
	if len(send.handles) == 0 {
		delete(t.sends, key)
	}
}

// expire records every awaited delivery of an acknowledged send that
// started before cutoff as missed, attributed to the send's start, and
// forgets the send. A send still waiting for its response is kept.
func (t *deliveryTracker) expire(cutoff time.Time) {
	now := t.now()
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, send := range t.sends {
		if !send.acked || !send.started.Before(cutoff) {
			continue
		}
		for _, h := range send.handles {
			t.rec.end(h, outcomeMissed, now.Sub(send.started))
		}
		delete(t.sends, key)
	}
}

// sweep expires deliveries past the deadline every interval until ctx is
// done.
func (t *deliveryTracker) sweep(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			t.expire(t.now().Add(-t.deadline))
		}
	}
}

// drain ends what is left once the load has stopped: deliveries past the
// deadline are missed, younger ones are unfinished (the run ended first).
// Only work after the last window remains by then.
func (t *deliveryTracker) drain() {
	t.expire(t.now().Add(-t.deadline))
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, send := range t.sends {
		for _, h := range send.handles {
			t.rec.abandon(h)
		}
		delete(t.sends, key)
	}
}

// size is the number of sends still tracked.
func (t *deliveryTracker) size() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.sends)
}

// expectedRecipients lists the clients that should see a realtime event for
// sender's message in conv: every client of an online member, except those
// on the sending device itself. The server publishes to every socket of
// each member account and runSocket ignores only the sender device's own
// events, so this matches what runSocket observes. A client whose socket
// is down when the message is sent still counts: realtime delivery missed
// it (the app recovers through catch-up, which is measured separately).
func (w *world) expectedRecipients(sender *device, conv conversation) []clientSlot {
	var expected []clientSlot
	for _, member := range conv.members {
		for slot, dev := range w.clients[member] {
			if dev.deviceID != sender.deviceID {
				expected = append(expected, clientSlot{dev: member, slot: slot})
			}
		}
	}
	return expected
}
