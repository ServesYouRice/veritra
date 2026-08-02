package httpapi

import (
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"strings"
	"sync"
	"time"
)

const maxLoginBackoffEntries = 32768

type LoginBackoff struct {
	salt [32]byte
	mu   sync.Mutex
	byID map[[32]byte]loginBackoffEntry
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
	if backoff == nil {
		return 0
	}
	key := backoff.key(identity)
	backoff.mu.Lock()
	defer backoff.mu.Unlock()
	entry, ok := backoff.byID[key]
	if !ok {
		return 0
	}
	if !entry.expiresAt.After(now) {
		delete(backoff.byID, key)
		return 0
	}
	if entry.blockedUntil.After(now) {
		return boundedBackoff(entry.blockedUntil.Sub(now))
	}
	return 0
}

func (backoff *LoginBackoff) Failed(identity string, now time.Time) time.Duration {
	if backoff == nil {
		return 0
	}
	key := backoff.key(identity)
	backoff.mu.Lock()
	defer backoff.mu.Unlock()
	if len(backoff.byID) >= maxLoginBackoffEntries {
		for existingKey, entry := range backoff.byID {
			if !entry.expiresAt.After(now) {
				delete(backoff.byID, existingKey)
			}
		}
	}
	entry := backoff.byID[key]
	entry.failures++
	entry.expiresAt = now.Add(15 * time.Minute)
	if entry.failures >= 3 {
		shift := entry.failures - 3
		if shift > 5 {
			shift = 5
		}
		delay := time.Second * time.Duration(1<<shift)
		entry.blockedUntil = now.Add(delay)
	}
	if len(backoff.byID) < maxLoginBackoffEntries || backoff.byID[key].failures > 0 {
		backoff.byID[key] = entry
	}
	return boundedBackoff(entry.blockedUntil.Sub(now))
}

func (backoff *LoginBackoff) Succeeded(identity string) {
	if backoff == nil {
		return
	}
	key := backoff.key(identity)
	backoff.mu.Lock()
	delete(backoff.byID, key)
	backoff.mu.Unlock()
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
