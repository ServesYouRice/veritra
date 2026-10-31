package httpapi

import "time"

// SetRecoveryLeaseRenewIntervalForTest shortens the recovery lease heartbeat
// so a test can watch it. The returned function restores the old interval.
func SetRecoveryLeaseRenewIntervalForTest(interval time.Duration) (restore func()) {
	previous := recoveryLeaseRenewInterval
	recoveryLeaseRenewInterval = interval
	return func() { recoveryLeaseRenewInterval = previous }
}

// SetLoginBackoffClockForTest replaces the clock the login handlers give the
// backoff. The returned function restores time.Now.
func SetLoginBackoffClockForTest(now func() time.Time) (restore func()) {
	previous := loginBackoffNow
	loginBackoffNow = now
	return func() { loginBackoffNow = previous }
}
