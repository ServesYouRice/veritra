package realtime

import (
	"errors"
	"testing"
)

func TestHubStatsCountDroppedEventsAndRejectedConnections(t *testing.T) {
	hub := NewHub()
	client, err := hub.Register("acct_a", "dev_a", "192.0.2.1")
	if err != nil {
		t.Fatal(err)
	}
	// Fill the socket buffer, then overflow it by three events.
	for i := 0; i < cap(client.send)+3; i++ {
		hub.Publish([]string{"acct_a"}, Event{Version: "v1", Type: "test"})
	}
	for i := 0; i < maxConnectionsPerDevice; i++ {
		if _, err := hub.Register("acct_a", "dev_b", "192.0.2.2"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := hub.Register("acct_a", "dev_b", "192.0.2.2"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("fourth socket for one device: %v", err)
	}
	hub.Drain()
	if _, err := hub.Register("acct_b", "dev_c", "192.0.2.3"); !errors.Is(err, ErrHubDraining) {
		t.Fatalf("register while draining: %v", err)
	}
	// A closed client drops nothing.
	hub.Publish([]string{"acct_a"}, Event{Version: "v1", Type: "test"})
	if stats := hub.Stats(); stats != (HubStats{DroppedEvents: 3, RejectedLimit: 1, RejectedDraining: 1}) {
		t.Fatalf("stats = %+v", stats)
	}
}
