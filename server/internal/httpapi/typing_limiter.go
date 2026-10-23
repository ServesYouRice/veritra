package httpapi

import (
	"sync"
	"time"
)

const (
	// typingInterval is the minimum gap between admitted typing updates for
	// one account/conversation pair.
	typingInterval = 2 * time.Second
	// typingMaxEntries hard-bounds the pairs held across both generations.
	// Reaching it needs that many distinct pairs admitted within two
	// intervals; further new pairs are refused until the next rotation.
	typingMaxEntries = 50_000
)

// typingLimiter admits at most one typing update per pair per
// typingInterval. Entries live in two time generations, each at most one
// interval wide: rotating drops the older generation wholesale, so expiry
// costs O(1) amortised instead of a sweep on every call. Only entries
// younger than typingInterval can throttle, and rotation keeps every such
// entry, so admission decisions match a full per-pair timestamp map.
// The zero value is ready to use.
type typingLimiter struct {
	mu        sync.Mutex
	current   map[string]time.Time
	previous  map[string]time.Time
	currentAt time.Time
}

func (l *typingLimiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	switch {
	case l.current == nil || !now.Before(l.currentAt.Add(2*typingInterval)):
		// Everything held is at least one interval old.
		l.previous = nil
		l.current = make(map[string]time.Time)
		l.currentAt = now
	case !now.Before(l.currentAt.Add(typingInterval)):
		// The current generation started at least one interval ago, so the
		// old previous generation holds only entries older than an interval.
		l.previous = l.current
		// Size for a steady load; bounded by typingMaxEntries.
		l.current = make(map[string]time.Time, len(l.previous))
		l.currentAt = now
	}
	last, inCurrent := l.current[key]
	if inCurrent && now.Sub(last) < typingInterval {
		return false
	}
	last, inPrevious := l.previous[key]
	if inPrevious && now.Sub(last) < typingInterval {
		return false
	}
	if !inCurrent && !inPrevious && len(l.current)+len(l.previous) >= typingMaxEntries {
		return false
	}
	delete(l.previous, key)
	l.current[key] = now
	return true
}

func (l *typingLimiter) entries() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.current) + len(l.previous)
}
