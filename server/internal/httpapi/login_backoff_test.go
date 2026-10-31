package httpapi

import (
	"context"
	"testing"
	"time"
)

func TestLoginBackoffEvictsAndContinuesApplyingNewEntries(t *testing.T) {
	backoff, err := NewLoginBackoff()
	if err != nil {
		t.Fatalf("new backoff: %v", err)
	}
	now := time.Now()
	for i := 0; i < maxLoginBackoffEntries; i++ {
		backoff.Failed("filler-"+itoa(i), now)
	}
	if entries, _ := backoff.Stats(); entries != maxLoginBackoffEntries {
		t.Fatalf("entries=%d want %d", entries, maxLoginBackoffEntries)
	}
	for attempt := 0; attempt < 3; attempt++ {
		backoff.Failed("new-client", now)
	}
	if retry := backoff.RetryAfter("new-client", now); retry <= 0 {
		t.Fatal("new entry did not receive backoff after table pressure")
	}
	if _, evictions := backoff.Stats(); evictions == 0 {
		t.Fatal("table-pressure eviction was not counted")
	}
}

// Filler identities must not be able to push out an account that is being
// guessed: eviction prefers the entries with the fewest failures (VAL-226).
func TestLoginBackoffEvictionPreservesHighFailureEntries(t *testing.T) {
	backoff, err := NewLoginBackoff()
	if err != nil {
		t.Fatalf("new backoff: %v", err)
	}
	backoff.maxEntries = 64
	now := time.Now()
	for i := 0; i < 10; i++ {
		backoff.Failed("hot-account", now)
	}
	// Past the block window, the hot entry is unblocked and its expiry is
	// older than every filler's.
	later := now.Add(2 * time.Minute)
	for i := 0; i < 1000; i++ {
		backoff.Failed("filler-"+itoa(i), later)
		if entries, _ := backoff.Stats(); entries > 64 {
			t.Fatalf("entries=%d exceed the capacity of 64", entries)
		}
	}
	backoff.mu.Lock()
	entry, ok := backoff.byID[backoff.key("hot-account")]
	backoff.mu.Unlock()
	if !ok || entry.failures != 10 {
		t.Fatalf("hot entry lost its accumulated failures: present=%v failures=%d", ok, entry.failures)
	}
	if retry := backoff.Failed("hot-account", later); retry < 16*time.Second {
		t.Fatalf("next failure of the hot account waits only %s", retry)
	}
}

func TestLoginBackoffCleanupLoopExpiresEntries(t *testing.T) {
	backoff, err := NewLoginBackoff()
	if err != nil {
		t.Fatalf("new backoff: %v", err)
	}
	now := time.Now()
	key := backoff.key("expired")
	backoff.byID[key] = loginBackoffEntry{expiresAt: now.Add(-time.Second)}
	backoff.removeExpiredLocked(now)
	if entries, _ := backoff.Stats(); entries != 0 {
		t.Fatalf("expired entries=%d", entries)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	backoff.CleanupLoop(ctx)
}

func itoa(value int) string {
	// Avoid importing a formatting package in this hot-path-focused test.
	if value == 0 {
		return "0"
	}
	var digits [20]byte
	index := len(digits)
	for value > 0 {
		index--
		digits[index] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[index:])
}
