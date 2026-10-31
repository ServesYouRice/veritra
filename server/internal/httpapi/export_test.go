package httpapi

import "time"

// SetRecoveryLeaseRenewIntervalForTest shortens the recovery lease heartbeat
// so a test can watch it. The returned function restores the old interval.
func SetRecoveryLeaseRenewIntervalForTest(interval time.Duration) (restore func()) {
	previous := recoveryLeaseRenewInterval
	recoveryLeaseRenewInterval = interval
	return func() { recoveryLeaseRenewInterval = previous }
}
