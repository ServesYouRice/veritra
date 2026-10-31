package storage

import (
	"context"
	"testing"
)

func TestDisablePushTargetIgnoresStaleTarget(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	id, err := store.CreatePushSubscription(ctx, owner.Account.ID, owner.Device.ID, "webpush", "https://push.example.test/old", "old-public-key", "old-auth-secret")
	if err != nil {
		t.Fatal(err)
	}
	subscriptions, err := store.ListDevicePushSubscriptions(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil || len(subscriptions) != 1 {
		t.Fatalf("subscriptions = %d, err = %v", len(subscriptions), err)
	}
	stale := subscriptions[0].Target()
	// The client registers again before the failed delivery is reported: same
	// id, new endpoint and credentials.
	refreshedID, err := store.CreatePushSubscription(ctx, owner.Account.ID, owner.Device.ID, "webpush", "https://push.example.test/new", "new-public-key", "new-auth-secret")
	if err != nil || refreshedID != id {
		t.Fatalf("refresh returned id %q, err = %v, want %q", refreshedID, err, id)
	}
	disabled := func() bool {
		return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM push_subscriptions WHERE id = ? AND disabled_at IS NOT NULL`, id) == 1
	}
	if err := store.DisablePushTarget(ctx, stale); err != nil {
		t.Fatal(err)
	}
	if disabled() {
		t.Fatal("a failure of the old registration disabled the refreshed one")
	}
	refreshed, err := store.ListDevicePushSubscriptions(ctx, owner.Account.ID, owner.Device.ID)
	if err != nil || len(refreshed) != 1 {
		t.Fatalf("refreshed subscriptions = %d, err = %v", len(refreshed), err)
	}
	if err := store.DisablePushTarget(ctx, refreshed[0].Target()); err != nil {
		t.Fatal(err)
	}
	if !disabled() {
		t.Fatal("the current target was not disabled")
	}
}
