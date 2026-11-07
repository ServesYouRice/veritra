package httpapi

import (
	"context"
	"errors"
	"time"

	"private-messenger/server/internal/push"
)

const recoveryWakeSendTimeout = 10 * time.Second

// wakeAccountDevices sends the ordinary generic "encrypted event available"
// wake to the account's devices (all but excludeDeviceID) after a recovery
// claim or its cancellation commits, so they sync and show the notice
// without waiting for the app to be opened (K0-R, D53). The payload is the
// provider's fixed generic wake: no names, text or claim details. It runs
// detached from the request, and a failure is only counted by class in the
// log: it never fails the claim or cancel. Targets and errors are never
// logged (they hold tokens and endpoints).
func (a *API) wakeAccountDevices(accountID, excludeDeviceID string) {
	if a.Push == nil || a.Store == nil {
		return
	}
	a.pushWakes.Add(1)
	go func() {
		defer a.pushWakes.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 4*recoveryWakeSendTimeout)
		defer cancel()
		targets, err := a.Store.PushTargetsForAccount(ctx, accountID, excludeDeviceID)
		if err != nil {
			a.warn("recovery_wake_targets_failed")
			return
		}
		failed := 0
		for _, target := range targets {
			sendCtx, sendCancel := context.WithTimeout(ctx, recoveryWakeSendTimeout)
			err := a.Push.SendEncryptedEventAvailable(sendCtx, push.Notification{
				NotificationMode: target.NotificationMode,
				Provider:         target.Provider, Endpoint: target.Endpoint,
				PublicKey: target.PublicKey, AuthSecret: target.AuthSecret,
			})
			sendCancel()
			switch {
			case err == nil:
			case errors.Is(err, push.ErrSubscriptionGone), errors.Is(err, push.ErrInvalidTarget):
				_ = a.Store.DisablePushTarget(ctx, target)
			default:
				failed++
			}
		}
		if failed > 0 {
			a.warn("recovery_wake_send_failed", "count", failed)
		}
	}()
}

// WaitPushWakes waits for account-level wakes still in flight. Tests use it;
// the request path never waits.
func (a *API) WaitPushWakes() { a.pushWakes.Wait() }
