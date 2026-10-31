package httpapi

// SetLoginBeforeSessionHookForTest runs hook between a login's password check
// and its session insert. The returned function removes it.
func SetLoginBeforeSessionHookForTest(hook func()) (restore func()) {
	previous := loginBeforeSessionHook
	loginBeforeSessionHook = hook
	return func() { loginBeforeSessionHook = previous }
}
