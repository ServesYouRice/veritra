package httpapi_test

import (
	"net/http"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/httpapi"
)

// legacyOwner gives the owner a bcrypt hash, so its next login rehashes, and
// returns that hash.
func legacyOwner(t *testing.T, owner rotationOwner) string {
	t.Helper()
	legacy, err := bcrypt.GenerateFromPassword([]byte("owner-password-123"), bcrypt.MinCost+6)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := owner.db.Exec(`UPDATE accounts SET password_hash = ?`, string(legacy)); err != nil {
		t.Fatal(err)
	}
	return string(legacy)
}

func countSessions(t *testing.T, owner rotationOwner) int {
	t.Helper()
	var n int
	if err := owner.db.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// A concurrent correct login that rehashes the password between this
// login's check and its session insert must not turn a correct password
// into "invalid_credentials".
func TestLoginSurvivesConcurrentRehash(t *testing.T) {
	owner := newRotationOwner(t)
	legacy := legacyOwner(t, owner)
	ran := 0
	t.Cleanup(httpapi.SetLoginBeforeSessionHookForTest(func() {
		ran++
		rehashed, err := auth.HashPassword("owner-password-123")
		if err != nil {
			t.Error(err)
			return
		}
		if _, err := owner.db.Exec(`UPDATE accounts SET password_hash = ? WHERE password_hash = ?`, rehashed, legacy); err != nil {
			t.Error(err)
		}
	}))
	before := countSessions(t, owner)
	got := owner.loginFrom(t, 30, "owner", "owner-password-123", owner.deviceID, owner.deviceSecret)
	if got.status != http.StatusOK {
		t.Fatalf("correct password after a concurrent rehash: %+v", got)
	}
	if ran != 1 {
		t.Fatalf("hook ran %d times", ran)
	}
	if after := countSessions(t, owner); after != before+1 {
		t.Fatalf("sessions %d -> %d, want one more", before, after)
	}
}

// A real password change in the same window still wins: the old password
// does not match the new hash, so no session is stored.
func TestLoginRefusedAfterConcurrentPasswordChange(t *testing.T) {
	owner := newRotationOwner(t)
	t.Cleanup(httpapi.SetLoginBeforeSessionHookForTest(func() {
		changed, err := auth.HashPassword("a-new-password-456")
		if err != nil {
			t.Error(err)
			return
		}
		if _, err := owner.db.Exec(`UPDATE accounts SET password_hash = ?`, changed); err != nil {
			t.Error(err)
		}
		if _, err := owner.db.Exec(`DELETE FROM sessions`); err != nil {
			t.Error(err)
		}
	}))
	got := owner.loginFrom(t, 31, "owner", "owner-password-123", owner.deviceID, owner.deviceSecret)
	if got.status != http.StatusUnauthorized {
		t.Fatalf("old password after a concurrent change: %+v", got)
	}
	if n := countSessions(t, owner); n != 0 {
		t.Fatalf("%d sessions outlived the password change", n)
	}
}
