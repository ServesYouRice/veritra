package httpapi

import (
	"context"
	"errors"
	"sync"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/push"
)

const recoveryWakeSendTimeout = 10 * time.Second

// accountWakes tracks the detached account-level wakes so shutdown can wait
// for them and then cancel what is left before storage closes (I46). A
// mutex-guarded count is used instead of a WaitGroup because a handler that
// the HTTP drain cut off may still start a wake while shutdown waits.
type accountWakes struct {
	mu      sync.Mutex
	running int
	stopped bool
	ctx     context.Context
	cancel  context.CancelFunc
}

// start registers one wake and returns its base context, or false once
// shutdown has stopped new wakes.
func (w *accountWakes) start() (context.Context, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.stopped {
		return nil, false
	}
	if w.ctx == nil {
		w.ctx, w.cancel = context.WithCancel(context.Background())
	}
	w.running++
	return w.ctx, true
}

func (w *accountWakes) done() {
	w.mu.Lock()
	w.running--
	w.mu.Unlock()
}

func (w *accountWakes) idle() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.running == 0
}

func (w *accountWakes) stop() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.stopped = true
	if w.cancel != nil {
		w.cancel()
	}
}

// wakeAccountDevices sends the generic "encrypted event available" wake to
// the account's local_decrypt_v1 (silent) devices (all but excludeDeviceID) after a recovery
// claim or its cancellation commits, so they sync and show the notice
// without waiting for the app to be opened (K0-R, D53). The payload is the
// provider's fixed generic wake: no names, text or claim details. It runs
// detached from the request, and a failure is only counted by class in the
// log: it never fails the claim or cancel. Legacy-mode subscriptions are
// skipped (owner decision 2026-11-07): their wake is a visible "New message"
// alert on APNs (D53), which D69 reserves for new messages. Those devices
// learn of the claim or cancel on their next sync. Targets and errors are never
// logged (they hold tokens and endpoints).
func (a *API) wakeAccountDevices(accountID, excludeDeviceID string) {
	if a.Push == nil || a.Store == nil {
		return
	}
	base, ok := a.pushWakes.start()
	if !ok {
		return
	}
	go func() {
		defer a.pushWakes.done()
		ctx, cancel := context.WithTimeout(base, 4*recoveryWakeSendTimeout)
		defer cancel()
		targets, err := a.Store.PushTargetsForAccount(ctx, accountID, excludeDeviceID)
		if err != nil {
			if ctx.Err() == nil {
				a.warn("recovery_wake_targets_failed")
			}
			return
		}
		failed := 0
		for _, target := range targets {
			if ctx.Err() != nil {
				return
			}
			if target.NotificationMode != domain.PushNotificationLocalDecrypt {
				continue
			}
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

// WaitPushWakes blocks until the account-level wakes in flight are done or
// the deadline passes, then stops new ones and cancels any still running.
// The server calls it before storage closes; the request path never waits.
func (a *API) WaitPushWakes(deadline time.Time) {
	for time.Now().Before(deadline) && !a.pushWakes.idle() {
		time.Sleep(10 * time.Millisecond)
	}
	a.pushWakes.stop()
	// Cancelled wakes return promptly; give them a short grace so none is
	// still touching storage when it closes.
	grace := time.Now().Add(time.Second)
	for time.Now().Before(grace) && !a.pushWakes.idle() {
		time.Sleep(5 * time.Millisecond)
	}
}
