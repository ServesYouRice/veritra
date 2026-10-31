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

// loginBackoffNow is the clock the login handlers give the backoff. Tests
// freeze it so a slow password check cannot outlast a one-second block.
var loginBackoffNow = time.Now

const backoffEvictionSampleSize = 32

type LoginBackoff struct {
	// maxEntries bounds the table; it defaults to maxLoginBackoffEntries and
	// tests lower it.
	maxEntries int
	salt       [32]byte
	mu         sync.Mutex
	byID       map[[32]byte]loginBackoffEntry
	evictions  atomic.Int64
}

type loginBackoffEntry struct {
	failures     int
	blockedUntil time.Time
	expiresAt    time.Time
}

func NewLoginBackoff() (*LoginBackoff, error) {
	backoff := &LoginBackoff{maxEntries: maxLoginBackoffEntries, byID: make(map[[32]byte]loginBackoffEntry)}
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
		if !exists && len(backoff.byID) >= backoff.maxEntries {
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

// evictOneLocked makes room by dropping one entry. Expired entries go first.
// Otherwise it samples backoffEvictionSampleSize entries and evicts the one
// that has recorded the fewest failures, so identities that are being guessed
// (many failures) outlast the one-failure filler entries an attacker can mint
// to push them out. Among equal counts an unblocked entry goes before a
// blocked one, then the earliest expiry.
func (backoff *LoginBackoff) evictOneLocked(now time.Time) {
	if len(backoff.byID) < backoff.maxEntries {
		return
	}
	var victim [32]byte
	var victimEntry loginBackoffEntry
	found := false
	sampled := 0
	for key, entry := range backoff.byID {
		if !entry.expiresAt.After(now) {
			delete(backoff.byID, key)
			if len(backoff.byID) < backoff.maxEntries {
				return
			}
			continue
		}
		if !found || evictsBefore(now, entry, victimEntry) {
			victim, victimEntry, found = key, entry, true
		}
		sampled++
		if sampled >= backoffEvictionSampleSize {
			break
		}
	}
	if found {
		delete(backoff.byID, victim)
		backoff.evictions.Add(1)
	}
}

// evictsBefore reports whether a is a better eviction victim than b.
func evictsBefore(now time.Time, a, b loginBackoffEntry) bool {
	if a.failures != b.failures {
		return a.failures < b.failures
	}
	if aBlocked, bBlocked := a.blockedUntil.After(now), b.blockedUntil.After(now); aBlocked != bBlocked {
		return !aBlocked
	}
	return a.expiresAt.Before(b.expiresAt)
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
