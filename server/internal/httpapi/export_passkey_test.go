package httpapi

// SetPasskeyBeforeSessionHookForTest runs hook between a passkey
// verification and its writer transaction. It returns the restore function.
func SetPasskeyBeforeSessionHookForTest(hook func()) (restore func()) {
	previous := passkeyBeforeSessionHook
	passkeyBeforeSessionHook = hook
	return func() { passkeyBeforeSessionHook = previous }
}
