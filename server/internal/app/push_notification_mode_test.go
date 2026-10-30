package app

import (
	"context"
	"private-messenger/server/internal/domain"
	"testing"
	"time"
)

func TestPushNotificationModeWorkerPropagatesSilentMutedWake(t *testing.T) {
	h := newPushHarness(t, nil)
	h.seed(t, 1)
	h.exec(t, `UPDATE push_subscriptions SET notification_mode='local_decrypt_v1' WHERE id=?`, pushTestSubscription)
	if err := h.app.Store.SetConversationNotificationMute(context.Background(), pushTestConversation, pushTestRecipient, true, nil); err != nil {
		t.Fatal(err)
	}
	if !h.app.drainPushWakeBatch(context.Background(), pushTestProvider) {
		t.Fatal("muted opt-in wake was not drained")
	}
	h.provider.mu.Lock()
	defer h.provider.mu.Unlock()
	if len(h.provider.calls) != 1 || h.provider.calls[0].NotificationMode != domain.PushNotificationLocalDecrypt {
		t.Fatalf("worker lost notification mode: %v", h.provider.calls)
	}
	h.assertPrivate(t)
}

func TestPushNotificationModeDowngradeBeforeDeliveryDropsMutedWake(t *testing.T) {
	h := newPushHarness(t, nil)
	h.seed(t, 1)
	h.exec(t, `UPDATE push_subscriptions SET notification_mode='local_decrypt_v1' WHERE id=?`, pushTestSubscription)
	if err := h.app.Store.SetConversationNotificationMute(context.Background(), pushTestConversation, pushTestRecipient, true, nil); err != nil {
		t.Fatal(err)
	}
	jobs, _, err := h.app.Store.ClaimPushWakeJobs(context.Background(), pushTestProvider, 1, time.Now(), time.Minute)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("claim %v %v", jobs, err)
	}
	h.exec(t, `UPDATE push_subscriptions SET notification_mode='legacy_generic' WHERE id=?`, pushTestSubscription)
	h.app.deliverPushWake(context.Background(), h.app.metrics.push[pushTestProvider], jobs[0])
	if h.provider.callCount() != 0 {
		t.Fatal("muted downgrade sent visible legacy wake")
	}
	if len(h.jobs(t)) != 0 {
		t.Fatal("downgraded queued job was not retired")
	}
	h.assertPrivate(t)
}
