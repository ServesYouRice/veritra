package storage

import (
	"context"
	"testing"
)

func TestCreatePushSubscriptionWithoutDeviceDeduplicates(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	other := owner.Account.ID

	active := func(query string, args ...any) int { return testRowCount(t, ctx, store, query, args...) }
	first, err := store.CreatePushSubscription(ctx, other, "", "fcm", "https://fcm.example/one", "", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.CreatePushSubscription(ctx, other, "", "fcm", "https://fcm.example/two", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("second device-less registration got id %s, want the first (%s) refreshed", second, first)
	}
	if n := active(`SELECT COUNT(*) FROM push_subscriptions WHERE account_id = ? AND device_id IS NULL AND disabled_at IS NULL`, other); n != 1 {
		t.Fatalf("active device-less subscriptions = %d, want 1", n)
	}
	var endpoint string
	if err := store.db.QueryRowContext(ctx, `SELECT endpoint FROM push_subscriptions WHERE id = ?`, first).Scan(&endpoint); err != nil || endpoint != "https://fcm.example/two" {
		t.Fatalf("endpoint = %q, err = %v, want the refreshed one", endpoint, err)
	}

	// A different provider retires the first, as it does for a device.
	apns, err := store.CreatePushSubscription(ctx, other, "", "apns", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if n := active(`SELECT COUNT(*) FROM push_subscriptions WHERE id = ? AND disabled_at IS NOT NULL`, first); n != 1 {
		t.Fatal("the fcm subscription stayed active after switching to apns")
	}
	if n := active(`SELECT COUNT(*) FROM push_subscriptions WHERE id = ? AND disabled_at IS NULL`, apns); n != 1 {
		t.Fatal("the apns subscription is not active")
	}

	// A registration of a real device is a separate scope and is untouched.
	deviceSub, err := store.CreatePushSubscription(ctx, other, owner.Device.ID, "fcm", "https://fcm.example/device", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if deviceSub == apns || deviceSub == first {
		t.Fatalf("device registration reused a device-less id %s", deviceSub)
	}
	if n := active(`SELECT COUNT(*) FROM push_subscriptions WHERE id = ? AND disabled_at IS NULL`, apns); n != 1 {
		t.Fatal("registering the device retired the device-less subscription")
	}
}
