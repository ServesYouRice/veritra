package httpapi_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/push"
)

type wakeRecorder struct {
	mu   sync.Mutex
	sent []push.Notification
	err  error
}

func (p *wakeRecorder) SendEncryptedEventAvailable(_ context.Context, n push.Notification) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sent = append(p.sent, n)
	return p.err
}

func (p *wakeRecorder) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.sent)
}

// waitFor waits for n sends, then checks that no extra one follows.
func (p *wakeRecorder) waitFor(t *testing.T, n int) []push.Notification {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for p.count() < n && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.sent) != n {
		t.Fatalf("wakes sent = %d, want %d", len(p.sent), n)
	}
	return append([]push.Notification(nil), p.sent...)
}

func newWakeFixture(t *testing.T, sendErr error) (*recoveryFixture, *wakeRecorder) {
	t.Helper()
	f := newRecoveryFixture(t, recoveryTestOrigin)
	rec := &wakeRecorder{err: sendErr}
	f.app.Push = rec
	f.handler = f.app.Handler()
	f.ownerRK = f.setRK(f.ownerToken)
	return f, rec
}

func (f *recoveryFixture) addPush(id, deviceID, endpoint string) {
	f.t.Helper()
	var device interface{}
	if deviceID != "" {
		device = deviceID
	}
	f.exec(`INSERT INTO push_subscriptions(id, account_id, device_id, provider, endpoint, public_key, auth_secret, created_at, notification_mode)
		VALUES(?, ?, ?, 'fcm', ?, '', '', ?, 'local_decrypt_v1')`,
		id, f.ownerAccountID, device, endpoint, recoveryTestTime(time.Now()))
}

func (f *recoveryFixture) reauth() {
	f.t.Helper()
	if status, body := f.do(http.MethodPost, "/api/v1/auth/reauth", f.ownerToken, map[string]string{"password": "owner-password-123", "device_secret": f.ownerDeviceSecret}, nil); status != http.StatusNoContent {
		f.t.Fatalf("reauth: %d %s", status, body)
	}
}

func (f *recoveryFixture) activeSubscriptions() int {
	return f.count(`SELECT COUNT(*) FROM push_subscriptions WHERE disabled_at IS NULL`)
}

func TestRecoveryClaimAndCancelSendAGenericAccountWake(t *testing.T) {
	f, rec := newWakeFixture(t, nil)
	f.addPush("push_owner", f.ownerDeviceID, "fcm-token-owner-0123456789-0123456789")

	claimed := f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	sent := rec.waitFor(t, 1)
	// The wake is the provider's fixed generic one: only the routing target
	// is set, nothing about the claim, its device name or the account.
	if got := sent[0]; got != (push.Notification{
		NotificationMode: "local_decrypt_v1", Provider: "fcm", Endpoint: "fcm-token-owner-0123456789-0123456789",
	}) {
		t.Fatalf("wake = %+v", got)
	}
	for _, leaked := range []string{claimed.RequestID, f.ownerAccountID, "owner phone", "recovery"} {
		if strings.Contains(fmt.Sprintf("%+v", sent[0]), leaked) {
			t.Fatalf("wake leaks %q: %+v", leaked, sent[0])
		}
	}

	// Cancel wakes the other devices, not the cancelling one.
	f.addPush("push_other", "", "fcm-token-other-0123456789-0123456789")
	f.reauth()
	if status, body := f.do(http.MethodPost, "/api/v1/account-recovery/"+claimed.RequestID+"/cancel", f.ownerToken, nil, nil); status != http.StatusOK {
		t.Fatalf("cancel: %d %s", status, body)
	}
	sent = rec.waitFor(t, 2)
	if sent[1].Endpoint != "fcm-token-other-0123456789-0123456789" {
		t.Fatalf("cancel wake went to %q, want the other device only", sent[1].Endpoint)
	}
}

func TestRecoveryWakeSkipsDisabledSubscriptions(t *testing.T) {
	f, rec := newWakeFixture(t, nil)
	f.addPush("push_live", f.ownerDeviceID, "fcm-live-0123456789-0123456789-0123")
	f.addPush("push_off", f.ownerDeviceID, "fcm-off-0123456789-0123456789-0123")
	f.exec(`UPDATE push_subscriptions SET disabled_at = ? WHERE id = 'push_off'`, recoveryTestTime(time.Now()))
	f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	if sent := rec.waitFor(t, 1); !strings.HasPrefix(sent[0].Endpoint, "fcm-live") {
		t.Fatalf("wake went to %q", sent[0].Endpoint)
	}
}

func TestRecoveryClaimAndCancelSurvivePushFailure(t *testing.T) {
	f, rec := newWakeFixture(t, errors.New("provider down: https://push.example/secret-token"))
	f.addPush("push_owner", f.ownerDeviceID, "fcm-token-owner-0123456789-0123456789")
	claimed := f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	rec.waitFor(t, 1)
	f.addPush("push_other", "", "fcm-token-other-0123456789-0123456789")
	f.reauth()
	if status, body := f.do(http.MethodPost, "/api/v1/account-recovery/"+claimed.RequestID+"/cancel", f.ownerToken, nil, nil); status != http.StatusOK {
		t.Fatalf("cancel with failing push: %d %s", status, body)
	}
	rec.waitFor(t, 2)
	// A transient failure leaves the registrations active.
	if n := f.activeSubscriptions(); n != 2 {
		t.Fatalf("active subscriptions after transient failure = %d", n)
	}
}

func TestRecoveryWakeRetiresGoneSubscriptions(t *testing.T) {
	f, rec := newWakeFixture(t, push.ErrSubscriptionGone)
	f.addPush("push_owner", f.ownerDeviceID, "fcm-token-owner-0123456789-0123456789")
	f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	rec.waitFor(t, 1)
	deadline := time.Now().Add(5 * time.Second)
	for f.activeSubscriptions() != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if n := f.activeSubscriptions(); n != 0 {
		t.Fatalf("gone subscription still active: %d", n)
	}
}
