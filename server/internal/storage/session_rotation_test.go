package storage

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/migrations"
)

type rotationFixture struct {
	store *Store
	owner AccountDevice
	t0    string
}

func newRotationFixture(t *testing.T, ctx context.Context) rotationFixture {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { _ = store.Close() })
	owner := createTestOwner(t, ctx, store)
	return rotationFixture{store: store, owner: owner, t0: newSessionForTest(t, ctx, store, owner)}
}

func newSessionForTest(t *testing.T, ctx context.Context, store *Store, owner AccountDevice) string {
	t.Helper()
	_, tokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("session token: %v", err)
	}
	if err := store.CreateSession(ctx, tokenHash, owner.Account.ID, owner.Device.ID, time.Time{}); err != nil {
		t.Fatalf("create session: %v", err)
	}
	return tokenHash
}

func newTokenHash(t *testing.T) string {
	t.Helper()
	_, tokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("token: %v", err)
	}
	return tokenHash
}

func (f rotationFixture) valid(t *testing.T, ctx context.Context, tokenHash string) bool {
	t.Helper()
	_, _, err := f.store.SessionPrincipal(ctx, tokenHash)
	if err != nil && !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("session principal: %v", err)
	}
	return err == nil
}

func (f rotationFixture) endGrace(t *testing.T, ctx context.Context) {
	t.Helper()
	if _, err := f.store.db.ExecContext(ctx, `UPDATE sessions SET previous_expires_at = ? WHERE previous_token_hash IS NOT NULL`, formatTime(time.Now().UTC().Add(-time.Millisecond))); err != nil {
		t.Fatalf("end grace: %v", err)
	}
}

func TestRotateSessionLeavesOneCurrentTokenAndAShortGrace(t *testing.T) {
	ctx := context.Background()
	f := newRotationFixture(t, ctx)
	t1 := newTokenHash(t)
	before := time.Now().UTC()
	if err := f.store.RotateSession(ctx, f.t0, t1); err != nil {
		t.Fatalf("rotate: %v", err)
	}

	current, activity, err := f.store.SessionPrincipal(ctx, t1)
	if err != nil || activity.RotatedOut || current.RecentAuthAt == nil || !current.RecentAuthAt.After(before.Add(-time.Second)) {
		t.Fatalf("new token: principal=%+v activity=%+v err=%v", current, activity, err)
	}
	old, oldActivity, err := f.store.SessionPrincipal(ctx, f.t0)
	if err != nil || !oldActivity.RotatedOut {
		t.Fatalf("rotated-out token inside grace: activity=%+v err=%v", oldActivity, err)
	}
	if old.RecentAuthAt != nil {
		t.Fatal("rotated-out token carries recent authentication")
	}
	if old.ExpiresAt.After(time.Now().UTC().Add(SessionRotationGrace)) {
		t.Fatalf("rotated-out token expires %s, after the grace", old.ExpiresAt)
	}
	if oldActivity.SessionTouchDue(time.Now().UTC().Add(time.Hour)) {
		t.Fatal("rotated-out token may extend the session")
	}
	if err := f.store.TouchSession(ctx, f.t0); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("touch with rotated-out token err=%v", err)
	}
	if err := f.store.MarkSessionRecentlyAuthenticated(ctx, f.t0); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("recent auth with rotated-out token err=%v", err)
	}

	f.endGrace(t, ctx)
	if f.valid(t, ctx, f.t0) {
		t.Fatal("rotated-out token valid after the grace")
	}
	if !f.valid(t, ctx, t1) {
		t.Fatal("new token lost with the grace")
	}
	if err := f.store.RotateSession(ctx, f.t0, newTokenHash(t)); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("rotation from an expired token err=%v", err)
	}
}

func TestRotateSessionRetryReplacesTheUnreceivedToken(t *testing.T) {
	ctx := context.Background()
	f := newRotationFixture(t, ctx)
	t1, t2 := newTokenHash(t), newTokenHash(t)
	if err := f.store.RotateSession(ctx, f.t0, t1); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	var graceBefore string
	if err := f.store.db.QueryRowContext(ctx, `SELECT previous_expires_at FROM sessions WHERE token_hash = ?`, t1).Scan(&graceBefore); err != nil {
		t.Fatalf("read grace: %v", err)
	}
	// The client never saw t1 and retries with t0.
	if err := f.store.RotateSession(ctx, f.t0, t2); err != nil {
		t.Fatalf("retry rotate: %v", err)
	}
	if f.valid(t, ctx, t1) {
		t.Fatal("unreceived token still valid after the retry")
	}
	if !f.valid(t, ctx, t2) || !f.valid(t, ctx, f.t0) {
		t.Fatal("retry lost the new token or the grace")
	}
	var graceAfter string
	if err := f.store.db.QueryRowContext(ctx, `SELECT previous_expires_at FROM sessions WHERE token_hash = ?`, t2).Scan(&graceAfter); err != nil {
		t.Fatalf("read grace: %v", err)
	}
	if graceAfter != graceBefore {
		t.Fatalf("retry extended the grace from %s to %s", graceBefore, graceAfter)
	}

	// Rotating again from the current token drops t0 at once.
	t3 := newTokenHash(t)
	if err := f.store.RotateSession(ctx, t2, t3); err != nil {
		t.Fatalf("second rotation: %v", err)
	}
	if f.valid(t, ctx, f.t0) || !f.valid(t, ctx, t2) || !f.valid(t, ctx, t3) {
		t.Fatalf("second rotation: t0=%v t2=%v t3=%v", f.valid(t, ctx, f.t0), f.valid(t, ctx, t2), f.valid(t, ctx, t3))
	}
}

func TestConcurrentRotationLeavesExactlyOneCurrentToken(t *testing.T) {
	ctx := context.Background()
	f := newRotationFixture(t, ctx)
	const racers = 8
	next := make([]string, racers)
	for i := range next {
		next[i] = newTokenHash(t)
	}
	var wg sync.WaitGroup
	errs := make([]error, racers)
	for i := range next {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = f.store.RotateSession(ctx, f.t0, next[i])
		}(i)
	}
	wg.Wait()
	current := 0
	for i, tokenHash := range next {
		if errs[i] != nil {
			t.Fatalf("rotation %d: %v", i, errs[i])
		}
		if f.valid(t, ctx, tokenHash) {
			current++
		}
	}
	if current != 1 {
		t.Fatalf("%d current tokens after concurrent rotation, want 1", current)
	}
	var rows int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sessions`).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("session rows=%d err=%v", rows, err)
	}
	if !f.valid(t, ctx, f.t0) {
		t.Fatal("original token lost its grace")
	}
	f.endGrace(t, ctx)
	if f.valid(t, ctx, f.t0) {
		t.Fatal("original token valid after the grace")
	}
}

func TestConcurrentRotationAndExpiry(t *testing.T) {
	ctx := context.Background()
	f := newRotationFixture(t, ctx)
	// The session expires while rotations race: none may resurrect it.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE sessions SET absolute_expires_at = ?`, formatTime(time.Now().UTC().Add(-time.Millisecond))); err != nil {
		t.Fatalf("expire: %v", err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := f.store.RotateSession(ctx, f.t0, newTokenHash(t)); !errors.Is(err, ErrUnauthorized) {
				t.Errorf("rotation of an expired session err=%v", err)
			}
		}()
	}
	wg.Wait()
}

func TestRotateSessionRejectsInvalidSessions(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	cases := map[string]string{
		"expired":          `UPDATE sessions SET expires_at = ?1`,
		"absolute_expired": `UPDATE sessions SET absolute_expires_at = ?1`,
		"idle_expired":     `UPDATE sessions SET last_used_at = ?2`,
		"logged_out":       `DELETE FROM sessions WHERE ?1 IS NOT NULL`,
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			f := newRotationFixture(t, ctx)
			if _, err := f.store.db.ExecContext(ctx, mutate, formatTime(now.Add(-time.Millisecond)), formatTime(now.Add(-SessionIdleLifetime-time.Second))); err != nil {
				t.Fatalf("mutate: %v", err)
			}
			if err := f.store.RotateSession(ctx, f.t0, newTokenHash(t)); !errors.Is(err, ErrUnauthorized) {
				t.Fatalf("rotate err=%v want %v", err, ErrUnauthorized)
			}
		})
	}
	f := newRotationFixture(t, ctx)
	for _, pair := range [][2]string{{"", newTokenHash(t)}, {f.t0, ""}, {f.t0, f.t0}} {
		if err := f.store.RotateSession(ctx, pair[0], pair[1]); !errors.Is(err, ErrUnauthorized) {
			t.Fatalf("rotate %q->%q err=%v", pair[0], pair[1], err)
		}
	}
}

func TestRotateSessionRenewsLifetimesAsAFreshAuthentication(t *testing.T) {
	ctx := context.Background()
	f := newRotationFixture(t, ctx)
	soon := time.Now().UTC().Add(time.Hour)
	if _, err := f.store.db.ExecContext(ctx, `UPDATE sessions SET expires_at = ?, absolute_expires_at = ?`, formatTime(soon), formatTime(soon)); err != nil {
		t.Fatalf("age session: %v", err)
	}
	t1 := newTokenHash(t)
	if err := f.store.RotateSession(ctx, f.t0, t1); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	var expires, absolute string
	if err := f.store.db.QueryRowContext(ctx, `SELECT expires_at, absolute_expires_at FROM sessions WHERE token_hash = ?`, t1).Scan(&expires, &absolute); err != nil {
		t.Fatalf("read lifetimes: %v", err)
	}
	minAbsolute := time.Now().UTC().Add(SessionAbsoluteLifetime - time.Minute)
	minIdle := time.Now().UTC().Add(SessionIdleLifetime - time.Minute)
	if parseTime(absolute).Before(minAbsolute) || parseTime(expires).Before(minIdle) || parseTime(expires).After(parseTime(absolute)) {
		t.Fatalf("rotation lifetimes expires=%s absolute=%s", expires, absolute)
	}
}

func TestRevocationCoversTheRotatedOutToken(t *testing.T) {
	ctx := context.Background()
	revocations := map[string]func(t *testing.T, f rotationFixture, t1 string){
		"logout_with_old_token": func(t *testing.T, f rotationFixture, _ string) {
			if err := f.store.DeleteSession(ctx, f.t0); err != nil {
				t.Fatalf("logout: %v", err)
			}
		},
		"logout_with_new_token": func(t *testing.T, f rotationFixture, t1 string) {
			if err := f.store.DeleteSession(ctx, t1); err != nil {
				t.Fatalf("logout: %v", err)
			}
		},
		"device_revoked": func(t *testing.T, f rotationFixture, _ string) {
			if err := f.store.RevokeDevice(ctx, f.owner.Account.ID, f.owner.Device.ID); err != nil {
				t.Fatalf("revoke device: %v", err)
			}
		},
		"owner_password_reset": func(t *testing.T, f rotationFixture, _ string) {
			hash, err := auth.HashPassword("owner-password-456")
			if err != nil {
				t.Fatalf("hash: %v", err)
			}
			if err := f.store.ResetOwnerPassword(ctx, "owner", hash); err != nil {
				t.Fatalf("reset: %v", err)
			}
		},
	}
	for name, revoke := range revocations {
		t.Run(name, func(t *testing.T) {
			f := newRotationFixture(t, ctx)
			t1 := newTokenHash(t)
			if err := f.store.RotateSession(ctx, f.t0, t1); err != nil {
				t.Fatalf("rotate: %v", err)
			}
			revoke(t, f, t1)
			if f.valid(t, ctx, f.t0) || f.valid(t, ctx, t1) {
				t.Fatalf("after %s: old=%v new=%v", name, f.valid(t, ctx, f.t0), f.valid(t, ctx, t1))
			}
		})
	}

	keepers := map[string]func(t *testing.T, f rotationFixture, keep string){
		"password_change": func(t *testing.T, f rotationFixture, keep string) {
			hash, err := auth.HashPassword("owner-password-456")
			if err != nil {
				t.Fatalf("hash: %v", err)
			}
			if err := f.store.ChangePassword(ctx, f.owner.Account.ID, keep, hash); err != nil {
				t.Fatalf("change password: %v", err)
			}
		},
		"logout_others": func(t *testing.T, f rotationFixture, keep string) {
			if _, err := f.store.DeleteAccountSessionsExcept(ctx, f.owner.Account.ID, keep); err != nil {
				t.Fatalf("logout others: %v", err)
			}
		},
	}
	for name, keepCurrent := range keepers {
		t.Run(name, func(t *testing.T) {
			f := newRotationFixture(t, ctx)
			other := newSessionForTest(t, ctx, f.store, f.owner)
			t1 := newTokenHash(t)
			if err := f.store.RotateSession(ctx, f.t0, t1); err != nil {
				t.Fatalf("rotate: %v", err)
			}
			keepCurrent(t, f, t1)
			if !f.valid(t, ctx, t1) || f.valid(t, ctx, f.t0) || f.valid(t, ctx, other) {
				t.Fatalf("after %s: kept=%v old=%v other=%v", name, f.valid(t, ctx, t1), f.valid(t, ctx, f.t0), f.valid(t, ctx, other))
			}
		})
	}
}

func TestTouchSessionDropsAnEndedGrace(t *testing.T) {
	ctx := context.Background()
	f := newRotationFixture(t, ctx)
	t1 := newTokenHash(t)
	if err := f.store.RotateSession(ctx, f.t0, t1); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	f.endGrace(t, ctx)
	old := time.Now().UTC().Add(-SessionTouchInterval - time.Second)
	setSessionTimes(t, ctx, f.store, t1, old, old.Add(SessionIdleLifetime))
	if err := f.store.TouchSession(ctx, t1); err != nil {
		t.Fatalf("touch: %v", err)
	}
	var previous *string
	if err := f.store.db.QueryRowContext(ctx, `SELECT previous_token_hash FROM sessions WHERE token_hash = ?`, t1).Scan(&previous); err != nil {
		t.Fatalf("read previous: %v", err)
	}
	if previous != nil {
		t.Fatal("touch kept a rotated-out token past its grace")
	}
}

func TestSessionLifetimesFollowConfiguration(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	store, err := Open(ctx, config.Config{
		DataDir:                 dir,
		DatabasePath:            filepath.Join(dir, "private-messenger.db"),
		StoragePath:             filepath.Join(dir, "blobs"),
		SessionIdleLifetime:     24 * time.Hour,
		SessionAbsoluteLifetime: 48 * time.Hour,
	})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	owner := createTestOwner(t, ctx, store)
	tokenHash := newSessionForTest(t, ctx, store, owner)
	var expires, absolute string
	if err := store.db.QueryRowContext(ctx, `SELECT expires_at, absolute_expires_at FROM sessions WHERE token_hash = ?`, tokenHash).Scan(&expires, &absolute); err != nil {
		t.Fatalf("read lifetimes: %v", err)
	}
	now := time.Now().UTC()
	if d := parseTime(expires).Sub(now); d < 23*time.Hour || d > 24*time.Hour {
		t.Fatalf("idle expiry in %s, want about 24h", d)
	}
	if d := parseTime(absolute).Sub(now); d < 47*time.Hour || d > 48*time.Hour {
		t.Fatalf("absolute expiry in %s, want about 48h", d)
	}
	setSessionTimes(t, ctx, store, tokenHash, now.Add(-25*time.Hour), now.Add(time.Hour))
	if _, _, err := store.SessionPrincipal(ctx, tokenHash); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("session idle past the configured lifetime err=%v", err)
	}
}

func TestHasLegacyPasswordHashes(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { _ = store.Close() })
	owner := createTestOwner(t, ctx, store)
	present, err := store.HasLegacyPasswordHashes(ctx)
	if err != nil || present {
		t.Fatalf("argon2id-only instance present=%v err=%v", present, err)
	}
	const legacy = "$2a$10$abcdefghijklmnopqrstuuJ6dE5fW8u0zX7jQ6q7Zl2bq5mU0eXyS"
	if _, err := store.db.ExecContext(ctx, `UPDATE accounts SET password_hash = ? WHERE id = ?`, legacy, owner.Account.ID); err != nil {
		t.Fatalf("set legacy: %v", err)
	}
	if present, err := store.HasLegacyPasswordHashes(ctx); err != nil || !present {
		t.Fatalf("legacy hash not seen: present=%v err=%v", present, err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE accounts SET deleted_at = ? WHERE id = ?`, nowString(), owner.Account.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if present, err := store.HasLegacyPasswordHashes(ctx); err != nil || present {
		t.Fatalf("deleted account counted: present=%v err=%v", present, err)
	}
}
