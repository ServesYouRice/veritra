package storage

import (
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
)

func newTouchTestSession(t *testing.T, ctx context.Context) (*Store, string) {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { _ = store.Close() })
	owner := createTestOwner(t, ctx, store)
	_, tokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("session token: %v", err)
	}
	if err := store.CreateSession(ctx, tokenHash, owner.Account.ID, owner.Device.ID, time.Now().UTC().Add(SessionIdleLifetime)); err != nil {
		t.Fatalf("create session: %v", err)
	}
	return store, tokenHash
}

func readSessionTimes(t *testing.T, ctx context.Context, store *Store, tokenHash string) (string, string) {
	t.Helper()
	var lastUsed, expires string
	if err := store.db.QueryRowContext(ctx, `SELECT last_used_at, expires_at FROM sessions WHERE token_hash = ?`, tokenHash).Scan(&lastUsed, &expires); err != nil {
		t.Fatalf("read session: %v", err)
	}
	return lastUsed, expires
}

func setSessionTimes(t *testing.T, ctx context.Context, store *Store, tokenHash string, lastUsed, expires time.Time) {
	t.Helper()
	if _, err := store.db.ExecContext(ctx, `UPDATE sessions SET last_used_at = ?, expires_at = ? WHERE token_hash = ?`, formatTime(lastUsed), formatTime(expires), tokenHash); err != nil {
		t.Fatalf("set session times: %v", err)
	}
}

func TestTouchSessionThrottlesRecentWrites(t *testing.T) {
	ctx := context.Background()
	store, tokenHash := newTouchTestSession(t, ctx)
	recent := time.Now().UTC().Add(-SessionTouchInterval / 2)
	setSessionTimes(t, ctx, store, tokenHash, recent, recent.Add(SessionIdleLifetime))
	beforeUsed, beforeExpires := readSessionTimes(t, ctx, store, tokenHash)

	if err := store.TouchSession(ctx, tokenHash); err != nil {
		t.Fatalf("throttled touch: %v", err)
	}
	afterUsed, afterExpires := readSessionTimes(t, ctx, store, tokenHash)
	if afterUsed != beforeUsed || afterExpires != beforeExpires {
		t.Fatalf("throttled touch wrote: used %q->%q expires %q->%q", beforeUsed, afterUsed, beforeExpires, afterExpires)
	}
	_, activity, err := store.SessionPrincipal(ctx, tokenHash)
	if err != nil {
		t.Fatalf("session principal: %v", err)
	}
	if activity.SessionTouchDue(time.Now().UTC()) {
		t.Fatalf("recent session reported touch due: %#v", activity)
	}
}

func TestTouchSessionWritesAfterInterval(t *testing.T) {
	ctx := context.Background()
	store, tokenHash := newTouchTestSession(t, ctx)
	old := time.Now().UTC().Add(-SessionTouchInterval - time.Second)
	setSessionTimes(t, ctx, store, tokenHash, old, old.Add(SessionIdleLifetime))
	_, activity, err := store.SessionPrincipal(ctx, tokenHash)
	if err != nil {
		t.Fatalf("session principal: %v", err)
	}
	if !activity.SessionTouchDue(time.Now().UTC()) {
		t.Fatalf("stale session did not report touch due: %#v", activity)
	}

	if err := store.TouchSession(ctx, tokenHash); err != nil {
		t.Fatalf("touch: %v", err)
	}
	afterUsed, afterExpires := readSessionTimes(t, ctx, store, tokenHash)
	if !parseTime(afterUsed).After(old) {
		t.Fatalf("last_used_at not advanced: %q", afterUsed)
	}
	if !parseTime(afterExpires).After(old.Add(SessionIdleLifetime)) {
		t.Fatalf("idle expiry not extended: %q", afterExpires)
	}
}

func TestTouchSessionStillRejectsInvalidSessions(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	cases := map[string]func(t *testing.T, store *Store, tokenHash string){
		"expired": func(t *testing.T, store *Store, tokenHash string) {
			// Recently used (inside the throttle window) but past expires_at.
			setSessionTimes(t, ctx, store, tokenHash, now.Add(-time.Second), now.Add(-time.Millisecond))
		},
		"idle_expired": func(t *testing.T, store *Store, tokenHash string) {
			setSessionTimes(t, ctx, store, tokenHash, now.Add(-SessionIdleLifetime-time.Second), now.Add(time.Hour))
		},
		"absolute_expired": func(t *testing.T, store *Store, tokenHash string) {
			setSessionTimes(t, ctx, store, tokenHash, now.Add(-time.Second), now.Add(time.Hour))
			if _, err := store.db.ExecContext(ctx, `UPDATE sessions SET absolute_expires_at = ? WHERE token_hash = ?`, formatTime(now.Add(-time.Millisecond)), tokenHash); err != nil {
				t.Fatalf("expire absolute: %v", err)
			}
		},
		"revoked": func(t *testing.T, store *Store, tokenHash string) {
			setSessionTimes(t, ctx, store, tokenHash, now.Add(-time.Second), now.Add(time.Hour))
			if _, err := store.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, tokenHash); err != nil {
				t.Fatalf("revoke: %v", err)
			}
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			store, tokenHash := newTouchTestSession(t, ctx)
			mutate(t, store, tokenHash)
			if err := store.TouchSession(ctx, tokenHash); !errors.Is(err, ErrUnauthorized) {
				t.Fatalf("touch err=%v want %v", err, ErrUnauthorized)
			}
			if _, _, err := store.SessionPrincipal(ctx, tokenHash); !errors.Is(err, ErrUnauthorized) {
				t.Fatalf("principal err=%v want %v", err, ErrUnauthorized)
			}
		})
	}
}

func TestSessionTouchIntervalIsTinyComparedWithIdleLifetime(t *testing.T) {
	if SessionTouchInterval*1000 > SessionIdleLifetime {
		t.Fatalf("touch interval %v too large for idle lifetime %v", SessionTouchInterval, SessionIdleLifetime)
	}
}
