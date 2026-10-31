package httpapi_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

type loginResult struct {
	status     int
	body       string
	retryAfter string
}

// loginFrom sends a login that appears to come from source, so tests can use
// many client addresses without tripping the per-address rate limiter.
func (o rotationOwner) loginFrom(t *testing.T, source int, username, password, deviceID, deviceSecret string) loginResult {
	t.Helper()
	raw, err := json.Marshal(map[string]string{
		"username": username, "password": password, "device_id": deviceID, "device_secret": deviceSecret,
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = fmt.Sprintf("198.51.100.%d:5000", source)
	rec := httptest.NewRecorder()
	o.handler.ServeHTTP(rec, req)
	return loginResult{status: rec.Code, body: rec.Body.String(), retryAfter: rec.Header().Get("Retry-After")}
}

// Failed logins for a known username from other sources, without that
// account's device secret, must not lock the owner out (VAL-225).
func TestLoginBackoffCannotBeTriggeredByThirdParty(t *testing.T) {
	owner := newRotationOwner(t)
	for i := 0; i < 12; i++ {
		got := owner.loginFrom(t, 10+i, "owner", "guess-password-123", fmt.Sprintf("dev_random_%d", i), "random-secret")
		if got.status != http.StatusUnauthorized {
			t.Fatalf("third-party attempt %d: %+v", i, got)
		}
	}
	// Even the real device id, with a wrong secret, from other sources.
	for i := 0; i < 6; i++ {
		got := owner.loginFrom(t, 40+i, "owner", "owner-password-123", owner.deviceID, "wrong-device-secret")
		if got.status != http.StatusUnauthorized {
			t.Fatalf("wrong-secret attempt %d: %+v", i, got)
		}
	}
	got := owner.loginFrom(t, 99, "owner", "owner-password-123", owner.deviceID, owner.deviceSecret)
	if got.status != http.StatusOK {
		t.Fatalf("the owner's login from a new source was refused: %+v", got)
	}
}

// Guessing the password with the device secret in hand is still bounded
// across sources (VAL-225).
func TestLoginBackoffStillBoundsGuessingWithDeviceSecret(t *testing.T) {
	owner := newRotationOwner(t)
	var last loginResult
	for i := 0; i < 5; i++ {
		last = owner.loginFrom(t, 10+i, "owner", "wrong-password-123", owner.deviceID, owner.deviceSecret)
		if i < 2 && last.status != http.StatusUnauthorized {
			t.Fatalf("attempt %d: %+v", i, last)
		}
	}
	if last.status != http.StatusTooManyRequests {
		t.Fatalf("guessing across sources was not limited: %+v", last)
	}
	if seconds, err := strconv.Atoi(last.retryAfter); err != nil || seconds < 1 || seconds > 60 {
		t.Fatalf("Retry-After=%q", last.retryAfter)
	}
	// While blocked, even the right password from a new source waits.
	if got := owner.loginFrom(t, 80, "owner", "owner-password-123", owner.deviceID, owner.deviceSecret); got.status != http.StatusTooManyRequests {
		t.Fatalf("right password during the account-device backoff: %+v", got)
	}
}

// With an invalid device secret, nothing observable depends on whether the
// password was right: same status, body and backoff progression, no rehash,
// and no effect on the account-device budget (VAL-304).
func TestLoginWithoutDeviceSecretDoesNotRevealPassword(t *testing.T) {
	owner := newRotationOwner(t)
	legacy, err := bcrypt.GenerateFromPassword([]byte("owner-password-123"), bcrypt.MinCost+6)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := owner.db.Exec(`UPDATE accounts SET password_hash = ?`, string(legacy)); err != nil {
		t.Fatal(err)
	}
	var correct, wrong []loginResult
	for i := 0; i < 3; i++ {
		correct = append(correct, owner.loginFrom(t, 20, "owner", "owner-password-123", owner.deviceID, "wrong-device-secret"))
		wrong = append(wrong, owner.loginFrom(t, 21, "owner", "wrong-password-123", owner.deviceID, "wrong-device-secret"))
	}
	for i := range correct {
		if correct[i] != wrong[i] {
			t.Fatalf("attempt %d differs: correct password %+v, wrong password %+v", i, correct[i], wrong[i])
		}
	}
	if correct[0].status != http.StatusUnauthorized || correct[2].status != http.StatusTooManyRequests {
		t.Fatalf("unexpected progression: %+v", correct)
	}
	var stored string
	if err := owner.db.QueryRow(`SELECT password_hash FROM accounts`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != string(legacy) {
		t.Fatal("a legacy hash was rehashed by a request without the device secret")
	}
	// Those failures were charged to their sources only: the owner, from a
	// third source, is not delayed.
	if got := owner.loginFrom(t, 22, "owner", "owner-password-123", owner.deviceID, owner.deviceSecret); got.status != http.StatusOK {
		t.Fatalf("owner login after the attempts: %+v", got)
	}
}
