package httpapi_test

import (
	"database/sql"
	"net/http"
	"testing"
	"time"

	"private-messenger/server/internal/storage"
)

const storedTimeLayout = "2006-01-02T15:04:05.000000000Z"

func storedTime(t time.Time) string { return t.UTC().Format(storedTimeLayout) }

func openSessionTestDB(t *testing.T, dbPath string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

type activitySnapshot struct {
	lastUsed, expires, deviceSeen string
}

func readActivity(t *testing.T, db *sql.DB) activitySnapshot {
	t.Helper()
	var snap activitySnapshot
	var deviceSeen sql.NullString
	if err := db.QueryRow(`SELECT s.last_used_at, s.expires_at, d.last_seen_at FROM sessions s JOIN devices d ON d.id = s.device_id`).Scan(&snap.lastUsed, &snap.expires, &deviceSeen); err != nil {
		t.Fatalf("read activity: %v", err)
	}
	snap.deviceSeen = deviceSeen.String
	return snap
}

func setActivity(t *testing.T, db *sql.DB, lastUsed, expires, deviceSeen time.Time) {
	t.Helper()
	if _, err := db.Exec(`UPDATE sessions SET last_used_at = ?, expires_at = ?`, storedTime(lastUsed), storedTime(expires)); err != nil {
		t.Fatalf("set session activity: %v", err)
	}
	if _, err := db.Exec(`UPDATE devices SET last_seen_at = ?`, storedTime(deviceSeen)); err != nil {
		t.Fatalf("set device activity: %v", err)
	}
}

func TestAuthenticatedRequestsThrottleActivityWrites(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	db := openSessionTestDB(t, dbPath)
	recent := time.Now().UTC().Add(-storage.SessionTouchInterval / 2)
	setActivity(t, db, recent, recent.Add(storage.SessionIdleLifetime), recent)
	before := readActivity(t, db)

	for i := 0; i < 3; i++ {
		status, response := doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", token, nil)
		if status != http.StatusOK {
			t.Fatalf("request %d status=%d body=%s", i, status, response)
		}
	}
	if after := readActivity(t, db); after != before {
		t.Fatalf("throttled requests wrote activity: before=%+v after=%+v", before, after)
	}
}

func TestAuthenticatedRequestWritesActivityAfterInterval(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	db := openSessionTestDB(t, dbPath)
	old := time.Now().UTC().Add(-storage.DeviceSeenInterval - time.Second)
	setActivity(t, db, old, old.Add(storage.SessionIdleLifetime), old)
	before := readActivity(t, db)

	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", token, nil)
	if status != http.StatusOK {
		t.Fatalf("status=%d body=%s", status, response)
	}
	after := readActivity(t, db)
	if after.lastUsed <= before.lastUsed || after.expires <= before.expires || after.deviceSeen <= before.deviceSeen {
		t.Fatalf("stale activity was not refreshed: before=%+v after=%+v", before, after)
	}
}

func TestAuthenticatedRequestRejectsExpiredSessionInsideThrottleWindow(t *testing.T) {
	now := time.Now().UTC()
	cases := map[string]func(t *testing.T, db *sql.DB){
		"expired": func(t *testing.T, db *sql.DB) {
			setActivity(t, db, now.Add(-time.Second), now.Add(-time.Millisecond), now)
		},
		"idle_expired": func(t *testing.T, db *sql.DB) {
			setActivity(t, db, now.Add(-storage.SessionIdleLifetime-time.Second), now.Add(time.Hour), now)
		},
		"absolute_expired": func(t *testing.T, db *sql.DB) {
			setActivity(t, db, now.Add(-time.Second), now.Add(time.Hour), now)
			if _, err := db.Exec(`UPDATE sessions SET absolute_expires_at = ?`, storedTime(now.Add(-time.Millisecond))); err != nil {
				t.Fatalf("expire absolute: %v", err)
			}
		},
		"revoked_session": func(t *testing.T, db *sql.DB) {
			setActivity(t, db, now.Add(-time.Second), now.Add(time.Hour), now)
			if _, err := db.Exec(`DELETE FROM sessions`); err != nil {
				t.Fatalf("revoke session: %v", err)
			}
		},
		"revoked_device": func(t *testing.T, db *sql.DB) {
			setActivity(t, db, now.Add(-time.Second), now.Add(time.Hour), now)
			if _, err := db.Exec(`UPDATE devices SET revoked_at = ?`, storedTime(now)); err != nil {
				t.Fatalf("revoke device: %v", err)
			}
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			handler, token, dbPath := newTestHandlerWithOwner(t)
			db := openSessionTestDB(t, dbPath)
			status, response := doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", token, nil)
			if status != http.StatusOK {
				t.Fatalf("live status=%d body=%s", status, response)
			}
			mutate(t, db)
			status, response = doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", token, nil)
			if status != http.StatusUnauthorized {
				t.Fatalf("status=%d body=%s want 401", status, response)
			}
		})
	}
}
