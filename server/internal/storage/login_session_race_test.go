package storage

import (
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
)

// C-da65d79b0ce1: a login reads and verifies the password hash, then stores
// a session. A password change committing in between deletes the account's
// sessions; the late login must not insert one that outlives it.
func TestLoginSessionRefusedAfterPasswordChangedMeanwhile(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)

	record, err := store.LoginRecord(ctx, owner.Account.Username, owner.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	// The password changes after the login verified the old hash.
	newHash, err := auth.HashPassword("a-new-password-456")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.ChangePassword(ctx, owner.Account.ID, "", newHash); err != nil {
		t.Fatal(err)
	}
	staleToken := auth.HashToken("stale-login-token")
	if err := store.CreateLoginSession(ctx, staleToken, record.AccountID, record.DeviceID, record.PasswordHash); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("session for a superseded hash: err = %v, want %v", err, ErrUnauthorized)
	}
	if _, err := store.PrincipalByTokenHash(ctx, staleToken); err == nil {
		t.Fatal("a session was stored for a password that no longer applies")
	}

	// A login that verified the current hash gets its session.
	record, err = store.LoginRecord(ctx, owner.Account.Username, owner.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	freshToken := auth.HashToken("fresh-login-token")
	if err := store.CreateLoginSession(ctx, freshToken, record.AccountID, record.DeviceID, record.PasswordHash); err != nil {
		t.Fatalf("session for the current hash: %v", err)
	}
	principal, err := store.PrincipalByTokenHash(ctx, freshToken)
	if err != nil || principal.AccountID != owner.Account.ID || principal.DeviceID != owner.Device.ID {
		t.Fatalf("principal = %#v, err = %v", principal, err)
	}
	var absolute string
	if err := store.db.QueryRowContext(ctx, `SELECT absolute_expires_at FROM sessions WHERE token_hash = ?`, freshToken).Scan(&absolute); err != nil {
		t.Fatal(err)
	}
	if !parseTime(absolute).After(time.Now()) {
		t.Fatalf("absolute expiry %s is not in the future", absolute)
	}
}
