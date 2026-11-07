package httpapi

import (
	"context"
	"net/http"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/push"
)

// blockingPush holds every send until its context ends.
type blockingPush struct{ started chan struct{} }

func (p *blockingPush) SendEncryptedEventAvailable(ctx context.Context, _ push.Notification) error {
	p.started <- struct{}{}
	<-ctx.Done()
	return ctx.Err()
}

func registerWakeTarget(t *testing.T, api *API, principal domain.Principal) {
	t.Helper()
	if status, body := call(t, api.createPushSubscription, principal, http.MethodPost,
		`{"provider":"fcm","endpoint":"`+fcmToken+`"}`); status != http.StatusCreated {
		t.Fatalf("register: %d %v", status, body)
	}
}

// K0-R shutdown (I46): a wake still blocked at the deadline is cancelled
// before storage closes, and no wake starts afterwards.
func TestRecoveryWakeStopsAtShutdownDeadline(t *testing.T) {
	api, principal, _ := newPushTestAPI(t, "fcm")
	registerWakeTarget(t, api, principal)
	blocked := &blockingPush{started: make(chan struct{}, 4)}
	api.Push = blocked

	api.wakeAccountDevices(principal.AccountID, "")
	select {
	case <-blocked.started:
	case <-time.After(5 * time.Second):
		t.Fatal("wake never reached the provider")
	}
	start := time.Now()
	api.WaitPushWakes(time.Now().Add(100 * time.Millisecond))
	if !api.pushWakes.idle() {
		t.Fatal("wake still running after WaitPushWakes returned")
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("WaitPushWakes took %s; the blocked send was not cancelled", elapsed)
	}

	api.wakeAccountDevices(principal.AccountID, "")
	select {
	case <-blocked.started:
		t.Fatal("a wake started after shutdown stopped them")
	case <-time.After(100 * time.Millisecond):
	}
	if !api.pushWakes.idle() {
		t.Fatal("a wake after stop was counted as running")
	}
}

func TestRecoveryWakeShutdownReturnsAtOnceWhenIdle(t *testing.T) {
	api, _, _ := newPushTestAPI(t, "fcm")
	start := time.Now()
	api.WaitPushWakes(time.Now().Add(10 * time.Second))
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("idle WaitPushWakes took %s", elapsed)
	}
}
