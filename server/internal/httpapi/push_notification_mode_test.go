package httpapi

import (
	"net/http"
	"private-messenger/server/internal/domain"
	"testing"
)

func TestPushNotificationModeRegistrationAndSilentSelfTest(t *testing.T) {
	api, principal, provider := newPushTestAPI(t, "fcm")
	for _, raw := range []string{`"unknown"`, `""`, `null`, `42`} {
		status, _ := call(t, api.createPushSubscription, principal, http.MethodPost, `{"provider":"fcm","endpoint":"`+fcmToken+`","notification_mode":`+raw+`}`)
		if status != http.StatusBadRequest {
			t.Fatalf("mode %s accepted %d", raw, status)
		}
	}
	status, created := call(t, api.createPushSubscription, principal, http.MethodPost, `{"provider":"fcm","endpoint":"`+fcmToken+`","notification_mode":"local_decrypt_v1"}`)
	if status != http.StatusCreated || created["notification_mode"] != domain.PushNotificationLocalDecrypt {
		t.Fatalf("optin response %d %v", status, created)
	}
	status, result := call(t, api.sendTestPush, principal, http.MethodPost, "")
	if status != http.StatusOK || len(provider.sent) != 1 || provider.sent[0].NotificationMode != domain.PushNotificationLocalDecrypt {
		t.Fatalf("selftest %d %v", status, result)
	}
	outcome := result["results"].([]any)[0].(map[string]any)
	if outcome["presentation"] != "none" || outcome["notification_mode"] != domain.PushNotificationLocalDecrypt {
		t.Fatalf("silent test claimed presentation: %v", outcome)
	}
	status, legacy := call(t, api.createPushSubscription, principal, http.MethodPost, `{"provider":"fcm","endpoint":"`+fcmToken+`-rotated"}`)
	if status != http.StatusCreated || legacy["subscription_id"] != created["subscription_id"] || legacy["notification_mode"] != domain.PushNotificationLegacy {
		t.Fatalf("omitted upsert %d %v", status, legacy)
	}
	_, list := call(t, api.listDevicePushSubscriptions, principal, http.MethodGet, "")
	if list["subscriptions"].([]any)[0].(map[string]any)["notification_mode"] != domain.PushNotificationLegacy {
		t.Fatalf("diagnostics mode %v", list)
	}
}
