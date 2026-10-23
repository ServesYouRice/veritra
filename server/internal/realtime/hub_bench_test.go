package realtime

import (
	"fmt"
	"testing"
	"time"
)

// T49A: realtime registration cost against the number of live sockets.
// Register holds the hub write lock; it originally counted every
// connection and now uses per-account and per-IP indexes.

func benchPopulateHub(b *testing.B, existing int) *Hub {
	b.Helper()
	hub := NewHub()
	for i := 0; i < existing; i++ {
		// Distinct account per socket; 10 sockets per synthetic IP stays
		// under the per-IP cap.
		if _, err := hub.Register(fmt.Sprintf("acct_%d", i), "dev", fmt.Sprintf("10.0.%d.%d", i/2550, (i/10)%255)); err != nil {
			b.Fatalf("populate %d: %v", i, err)
		}
	}
	return hub
}

func BenchmarkHubRegister(b *testing.B) {
	for _, existing := range []int{0, 1_000, 5_000, 9_000} {
		hub := benchPopulateHub(b, existing)
		b.Run(fmt.Sprintf("sockets%d", existing), func(b *testing.B) {
			for b.Loop() {
				client, err := hub.Register("acct_new", "dev_new", "192.0.2.1")
				if err != nil {
					b.Fatal(err)
				}
				hub.Unregister(client)
			}
		})
		b.Run(fmt.Sprintf("sockets%d/Parallel", existing), func(b *testing.B) {
			b.RunParallel(func(pb *testing.PB) {
				for pb.Next() {
					client, err := hub.Register("acct_par", "dev_par", "192.0.2.2")
					if err != nil {
						// Concurrent registrations can hit the per-device cap.
						continue
					}
					hub.Unregister(client)
				}
			})
		})
	}
}

// Publish while registrations churn: fan-out readers share the hub lock.
func BenchmarkHubPublish(b *testing.B) {
	for _, existing := range []int{1_000, 9_000} {
		hub := benchPopulateHub(b, existing)
		recipients := make([]string, 0, 5)
		for i := 0; i < 5; i++ {
			recipients = append(recipients, fmt.Sprintf("acct_%d", i))
		}
		event := Event{Version: "v1", Type: "message.envelope.created", ID: 1, ConversationID: "conv_x", Payload: map[string]string{"message_id": "msg_x"}, CreatedAt: time.Unix(0, 0).UTC()}
		b.Run(fmt.Sprintf("sockets%d", existing), func(b *testing.B) {
			for b.Loop() {
				hub.Publish(recipients, event)
				// Keep the bounded buffers from filling so every send is real.
				for _, account := range recipients {
					for client := range hub.subscribers[account] {
						select {
						case <-client.send:
						default:
						}
					}
				}
			}
		})
	}
}
