package httpapi

import (
	"context"

	"private-messenger/server/internal/auth"
)

// SetHashNewPasswordForTest replaces the new-account password hasher and
// returns a function that restores it.
func SetHashNewPasswordForTest(hash func(context.Context, auth.Caller, string) (string, error)) func() {
	previous := hashNewPassword
	hashNewPassword = hash
	return func() { hashNewPassword = previous }
}
