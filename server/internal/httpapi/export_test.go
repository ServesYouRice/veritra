package httpapi

import "time"

// SetLoginBackoffClockForTest replaces the clock the login handlers give the
// backoff. The returned function restores time.Now.
func SetLoginBackoffClockForTest(now func() time.Time) (restore func()) {
	previous := loginBackoffNow
	loginBackoffNow = now
	return func() { loginBackoffNow = previous }
}
