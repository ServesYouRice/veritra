package storage

import (
	"context"
	"testing"
)

func TestMarkDeviceSeenIsThrottled(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)

	if err := store.MarkDeviceSeen(ctx, owner.Device.ID); err != nil {
		t.Fatalf("mark device seen: %v", err)
	}
	devices, err := store.ListDevices(ctx, owner.Account.ID)
	if err != nil {
		t.Fatalf("list devices: %v", err)
	}
	if len(devices) != 1 || devices[0].LastSeenAt == nil {
		t.Fatalf("last seen not recorded: %#v", devices)
	}
	first := *devices[0].LastSeenAt

	if err := store.MarkDeviceSeen(ctx, owner.Device.ID); err != nil {
		t.Fatalf("mark device seen again: %v", err)
	}
	devices, err = store.ListDevices(ctx, owner.Account.ID)
	if err != nil {
		t.Fatalf("list devices again: %v", err)
	}
	if devices[0].LastSeenAt == nil || !devices[0].LastSeenAt.Equal(first) {
		t.Fatalf("last seen write was not throttled: first=%v devices=%#v", first, devices)
	}
}
