package httpapi

import (
	"fmt"
	"testing"
	"time"
)

// T49A: typing-state growth. allowTyping keeps one entry per
// account/conversation pair and sweeps entries older than a minute only
// once the map exceeds 10,000 entries; the sweep runs on every admitted
// call while the map stays over the cap.

// Steady state: active pairs each send one typing update every 3s, so all
// entries stay fresh and the map size equals the active pair count.
func BenchmarkTypingAllowSteady(b *testing.B) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for _, active := range []int{1_000, 5_000, 10_001, 20_000} {
		b.Run(fmt.Sprintf("active%d", active), func(b *testing.B) {
			api := &API{}
			keys := make([]string, active)
			for i := range keys {
				keys[i] = fmt.Sprintf("acct_%d", i)
				api.allowTyping(keys[i], "conv", base)
			}
			i := 0
			for b.Loop() {
				round := i/active + 1
				api.allowTyping(keys[i%active], "conv", base.Add(time.Duration(round)*3*time.Second))
				i++
			}
			b.ReportMetric(float64(len(api.typingLast)), "entries")
		})
	}
}

// Burst: distinct pairs start typing within one minute. One op inserts the
// whole burst into empty state, which exposes the per-call sweep cost.
func BenchmarkTypingAllowBurst(b *testing.B) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for _, pairs := range []int{5_000, 10_000, 20_000} {
		keys := make([]string, pairs)
		for i := range keys {
			keys[i] = fmt.Sprintf("acct_%d", i)
		}
		b.Run(fmt.Sprintf("pairs%d", pairs), func(b *testing.B) {
			for b.Loop() {
				api := &API{}
				for _, key := range keys {
					api.allowTyping(key, "conv", now)
				}
			}
			b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*pairs), "ns/call")
		})
	}
}

func BenchmarkTypingAllowThrottled(b *testing.B) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	api := &API{}
	api.allowTyping("acct", "conv", now)
	for b.Loop() {
		if api.allowTyping("acct", "conv", now.Add(time.Second)) {
			b.Fatal("expected throttle")
		}
	}
}
