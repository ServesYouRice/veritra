package httpapi

// SetRecoveryClaimWorkHookForTest observes the expensive and stateful steps
// of every recovery claim. The returned function removes the hook.
func SetRecoveryClaimWorkHookForTest(hook func(step string)) (restore func()) {
	previous := recoveryClaimWorkHook
	recoveryClaimWorkHook = hook
	return func() { recoveryClaimWorkHook = previous }
}
