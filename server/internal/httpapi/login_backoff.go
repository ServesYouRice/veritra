package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const maxLoginBackoffEntries = 32768

const backoffEvictionSampleSize = 32

type LoginBackoff struct {
	salt      [32]byte
	mu        sync.Mutex
	byID      map[[32]byte]loginBackoffEntry
	evictions atomic.Int64
}

type loginBackoffEntry struct {
	failures     int
	blockedUntil time.Time
	expiresAt    time.Time
}

func NewLoginBackoff() (*LoginBackoff, error) {
	backoff := &LoginBackoff{byID: make(map[[32]byte]loginBackoffEntry)}
	if _, err := rand.Read(backoff.salt[:]); err != nil {
		return nil, fmt.Errorf("initialize login backoff: %w", err)
	}
	return backoff, nil
}

func (backoff *LoginBackoff) RetryAfter(identity string, now time.Time) time.Duration {
	return backoff.RetryAfterAny(now, identity)
}

// RetryAfterAny returns the longest active delay for the supplied anonymous
// credential scopes. Keeping the scopes separate prevents a source change
// from discarding an account/session budget.
func (backoff *LoginBackoff) RetryAfterAny(now time.Time, identities ...string) time.Duration {
	if backoff == nil {
		return 0
	}
	backoff.mu.Lock()
	defer backoff.mu.Unlock()
	var longest time.Duration
	for _, identity := range uniqueBackoffIdentities(identities) {
		key := backoff.key(identity)
		entry, ok := backoff.byID[key]
		if !ok {
			continue
		}
		if !entry.expiresAt.After(now) {
			delete(backoff.byID, key)
			continue
		}
		if entry.blockedUntil.After(now) && entry.blockedUntil.Sub(now) > longest {
			longest = entry.blockedUntil.Sub(now)
		}
	}
	return boundedBackoff(longest)
}

func (backoff *LoginBackoff) Failed(identity string, now time.Time) time.Duration {
	return backoff.FailedAny(now, identity)
}

// FailedAny records one failed credential attempt in each supplied scope and
// returns the longest delay. The caller can therefore combine account, source,
// device, and session budgets without exposing any of those values in metrics.
func (backoff *LoginBackoff) FailedAny(now time.Time, identities ...string) time.Duration {
	if backoff == nil {
		return 0
	}
	backoff.mu.Lock()
	defer backoff.mu.Unlock()
	var longest time.Duration
	for _, identity := range uniqueBackoffIdentities(identities) {
		key := backoff.key(identity)
		entry, exists := backoff.byID[key]
		if exists && !entry.expiresAt.After(now) {
			delete(backoff.byID, key)
			exists = false
		}
		if !exists && len(backoff.byID) >= maxLoginBackoffEntries {
			backoff.evictOneLocked(now)
		}
		entry.failures++
		if !exists {
			entry.expiresAt = now.Add(15 * time.Minute)
		} else if !entry.expiresAt.After(now) {
			entry.expiresAt = now.Add(15 * time.Minute)
		}
		if entry.failures >= 3 {
			shift := entry.failures - 3
			if shift > 5 {
				shift = 5
			}
			delay := time.Second * time.Duration(1<<shift)
			entry.blockedUntil = now.Add(delay)
		}
		backoff.byID[key] = entry
		if entry.blockedUntil.After(now) && entry.blockedUntil.Sub(now) > longest {
			longest = entry.blockedUntil.Sub(now)
		}
	}
	return boundedBackoff(longest)
}

func (backoff *LoginBackoff) Succeeded(identity string) {
	backoff.SucceededAny(identity)
}

func (backoff *LoginBackoff) SucceededAny(identities ...string) {
	if backoff == nil {
		return
	}
	backoff.mu.Lock()
	for _, identity := range uniqueBackoffIdentities(identities) {
		delete(backoff.byID, backoff.key(identity))
	}
	backoff.mu.Unlock()
}

// CleanupLoop removes expired entries even when no further login arrives.
func (backoff *LoginBackoff) CleanupLoop(ctx context.Context) {
	if backoff == nil {
		return
	}
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			backoff.mu.Lock()
			backoff.removeExpiredLocked(now)
			backoff.mu.Unlock()
		}
	}
}

// Stats reports aggregate state only. It intentionally contains no identity
// or source information.
func (backoff *LoginBackoff) Stats() (entries int, evictions int64) {
	if backoff == nil {
		return 0, 0
	}
	backoff.mu.Lock()
	entries = len(backoff.byID)
	backoff.mu.Unlock()
	return entries, backoff.evictions.Load()
}

func (backoff *LoginBackoff) removeExpiredLocked(now time.Time) {
	for key, entry := range backoff.byID {
		if !entry.expiresAt.After(now) {
			delete(backoff.byID, key)
		}
	}
}

func (backoff *LoginBackoff) evictOneLocked(now time.Time) {
	if len(backoff.byID) < maxLoginBackoffEntries {
		return
	}
	var fallback [32]byte
	var fallbackEntry loginBackoffEntry
	fallbackFound := false
	var preferred [32]byte
	var preferredEntry loginBackoffEntry
	preferredFound := false
	sampled := 0
	for key, entry := range backoff.byID {
		if !entry.expiresAt.After(now) {
			delete(backoff.byID, key)
			if len(backoff.byID) < maxLoginBackoffEntries {
				return
			}
			continue
		}
		if !fallbackFound || entry.expiresAt.Before(fallbackEntry.expiresAt) {
			fallback, fallbackEntry, fallbackFound = key, entry, true
		}
		if !entry.blockedUntil.After(now) && (!preferredFound || entry.expiresAt.Before(preferredEntry.expiresAt)) {
			preferred, preferredEntry, preferredFound = key, entry, true
		}
		sampled++
		if sampled >= backoffEvictionSampleSize {
			break
		}
	}
	candidate := fallback
	if preferredFound {
		candidate = preferred
	}
	if fallbackFound {
		delete(backoff.byID, candidate)
		backoff.evictions.Add(1)
	}
}

func uniqueBackoffIdentities(identities []string) []string {
	seen := make(map[string]struct{}, len(identities))
	unique := make([]string, 0, len(identities))
	for _, identity := range identities {
		if _, ok := seen[identity]; ok {
			continue
		}
		seen[identity] = struct{}{}
		unique = append(unique, identity)
	}
	return unique
}

func (backoff *LoginBackoff) key(identity string) [32]byte {
	normalized := strings.ToLower(strings.TrimSpace(identity))
	input := make([]byte, 0, len(backoff.salt)+len(normalized))
	input = append(input, backoff.salt[:]...)
	input = append(input, normalized...)
	return sha256.Sum256(input)
}

func boundedBackoff(duration time.Duration) time.Duration {
	if duration <= 0 {
		return 0
	}
	if duration > 60*time.Second {
		return 60 * time.Second
	}
	return duration
}
