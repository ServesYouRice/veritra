package storage

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

func TestPushNotificationModeIsSubscriptionScopedAndDowngradeSafe(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	peer := registerTestMember(t, ctx, store, invite.Code, "silentpeer")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{peer.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	register := func(mode string) string {
		t.Helper()
		id, err := store.CreatePushSubscriptionWithMode(ctx, peer.Account.ID, peer.Device.ID, "fcm", strings.Repeat("a", 40), "", "", mode)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	id := register(domain.PushNotificationLocalDecrypt)
	otherDevice, err := domain.NewID("dev")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `INSERT INTO devices(id,account_id,name,key_package,created_at) VALUES(?,?,?,X'01',?)`, otherDevice, peer.Account.ID, "legacy second device", nowString()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreatePushSubscription(ctx, peer.Account.ID, otherDevice, "fcm", strings.Repeat("c", 40), "", ""); err != nil {
		t.Fatal(err)
	}
	if err := store.SetConversationNotificationMute(ctx, conversation.ID, peer.Account.ID, true, nil); err != nil {
		t.Fatal(err)
	}
	send := func(key string) {
		t.Helper()
		_, _, _, err := store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{ConversationID: conversation.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID, IdempotencyKey: key, Ciphertext: []byte("opaque encrypted body"), CryptoProtocol: "mls-openmls-todo"})
		if err != nil {
			t.Fatal(err)
		}
	}
	send("optin-muted")
	jobs, _, err := store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now(), time.Minute)
	if err != nil || len(jobs) != 1 || jobs[0].NotificationMode != domain.PushNotificationLocalDecrypt {
		t.Fatalf("silent muted claim %v %v", jobs, err)
	}
	if _, err := store.RefreshPushWakeJob(ctx, jobs[0], time.Now()); err != nil {
		t.Fatal(err)
	}
	reset, err := store.CreatePushSubscription(ctx, peer.Account.ID, peer.Device.ID, "fcm", strings.Repeat("b", 40), "", "")
	if err != nil || reset != id {
		t.Fatalf("legacy upsert %s %v", reset, err)
	}
	if _, err := store.RefreshPushWakeJob(ctx, jobs[0], time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("downgrade delivered muted legacy wake: %v", err)
	}
	if err := store.DropPushWakeJob(ctx, jobs[0]); err != nil {
		t.Fatal(err)
	}
	send("legacy-muted")
	jobs, _, err = store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now(), time.Minute)
	if err != nil || len(jobs) != 0 {
		t.Fatalf("legacy mute bypass %v %v", jobs, err)
	}
	register(domain.PushNotificationLocalDecrypt)
	send("downgrade-before-claim")
	register(domain.PushNotificationLegacy)
	jobs, _, err = store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now(), time.Minute)
	if err != nil || len(jobs) != 0 {
		t.Fatalf("queued downgrade claimed %v %v", jobs, err)
	}
	if err := store.SetConversationNotificationMute(ctx, conversation.ID, peer.Account.ID, false, nil); err != nil {
		t.Fatal(err)
	}
	jobs, _, err = store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now(), time.Minute)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("unmute pending %v %v", jobs, err)
	}
	if jobs[0].NotificationMode != domain.PushNotificationLegacy {
		t.Fatal("claim used stale mode")
	}
	register(domain.PushNotificationLocalDecrypt)
	fresh, err := store.RefreshPushWakeJob(ctx, jobs[0], time.Now())
	if err != nil || fresh.NotificationMode != domain.PushNotificationLocalDecrypt {
		t.Fatalf("refresh stale mode %v %v", fresh, err)
	}
	if _, err := store.db.ExecContext(ctx, `INSERT INTO account_blocks(blocker_account_id,blocked_account_id,created_at) VALUES(?,?,?)`, peer.Account.ID, owner.Account.ID, nowString()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RefreshPushWakeJob(ctx, jobs[0], time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatal("opt-in bypassed sender block")
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM account_blocks WHERE blocker_account_id=? AND blocked_account_id=?`, peer.Account.ID, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `DELETE FROM memberships WHERE account_id=? AND conversation_id=?`, peer.Account.ID, conversation.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RefreshPushWakeJob(ctx, jobs[0], time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatal("opt-in bypassed membership removal")
	}
	if err := store.AddConversationMember(ctx, conversation.ID, peer.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	current, err := store.DevicePushSubscriptionForDevice(ctx, id, peer.Account.ID, peer.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.DisablePushTarget(ctx, current.Target()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RefreshPushWakeJob(ctx, jobs[0], time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatal("opt-in bypassed disabled subscription")
	}
	if err := store.RevokeDevice(ctx, peer.Account.ID, peer.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.RefreshPushWakeJob(ctx, jobs[0], time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("revoked device woke %v", err)
	}
	if _, err := store.DevicePushSubscriptionForDevice(ctx, id, peer.Account.ID, peer.Device.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("revoked selftest %v", err)
	}
}

func TestPushNotificationModeDefaultAndValidation(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	for _, deviceID := range []string{"", "not-a-current-device"} {
		if _, err := store.CreatePushSubscriptionWithMode(ctx, owner.Account.ID, deviceID, "fcm", "token", "", "", domain.PushNotificationLocalDecrypt); !errors.Is(err, ErrUnauthorized) {
			t.Fatalf("non-device capability %q: %v", deviceID, err)
		}
	}
	if _, err := store.CreatePushSubscriptionWithMode(ctx, "different-account", owner.Device.ID, "fcm", "token", "", "", domain.PushNotificationLocalDecrypt); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("mismatched-device capability %v", err)
	}
	for _, mode := range []string{"", "LOCAL_DECRYPT_V1", "none", "local_decrypt_v2"} {
		if _, err := store.CreatePushSubscriptionWithMode(ctx, owner.Account.ID, owner.Device.ID, "fcm", "token", "", "", mode); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("invalid mode %q: %v", mode, err)
		}
	}
	id, err := store.CreatePushSubscription(ctx, owner.Account.ID, owner.Device.ID, "fcm", "token", "", "")
	if err != nil {
		t.Fatal(err)
	}
	subscriptions, err := store.ListDevicePushSubscriptions(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil || len(subscriptions) != 1 || subscriptions[0].NotificationMode != domain.PushNotificationLegacy {
		t.Fatalf("default %v %v", subscriptions, err)
	}
	if _, err := store.DevicePushSubscriptionForDevice(ctx, id, owner.Account.ID, "different-device"); !errors.Is(err, ErrNotFound) {
		t.Fatal("self-test target escaped device scope")
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE accounts SET status='suspended' WHERE id=?`, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreatePushSubscriptionWithMode(ctx, owner.Account.ID, owner.Device.ID, "fcm", "token", "", "", domain.PushNotificationLocalDecrypt); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("inactive capability %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE accounts SET status='active' WHERE id=?`, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET revoked_at=? WHERE id=?`, nowString(), owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreatePushSubscriptionWithMode(ctx, owner.Account.ID, owner.Device.ID, "fcm", "token", "", "", domain.PushNotificationLocalDecrypt); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked-device capability %v", err)
	}
}
