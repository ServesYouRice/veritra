package storage

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TASK-201 for protocol v3 (D100/D114 remedy d): approval inserts the
// recipient device, but a link not completed by its first-completion
// deadline can never mint a session. The prune cancels it: the device is
// revoked (event, MLS removal), its unclaimed key packages are deleted and
// its link context is gone, so no active device is left that nobody holds.
func TestApprovedDeviceLinkV3ExpiryCancelsTheNeverUsedDevice(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	approved := f.approve(t)
	deviceID := f.reservation.DeviceID
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, deviceID); n != 1 {
		t.Fatal("test premise: approval did not create an active device")
	}
	// Inside the window the prune leaves it alone.
	if _, err := f.store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, deviceID); n != 1 {
		t.Fatal("the prune revoked an approved device inside its window")
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE device_links_v3 SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Second)), f.link.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.store.CompleteDeviceLinkV3(ctx, f.link.ID, f.input.ClaimTokenHash, approved.ClaimRequestHash, f.input.InitialSessionTokenHash, f.input.TranscriptHash); !errors.Is(err, ErrDeviceLinkInvalid) {
		t.Fatalf("test premise: completion after the deadline = %v, want ErrDeviceLinkInvalid", err)
	}
	if _, err := f.store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NOT NULL`, deviceID); n != 1 {
		t.Fatal("the never-completed device is still active")
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ? AND claimed_at IS NULL`, deviceID); n != 0 {
		t.Fatalf("%d unclaimed key packages remain for the cancelled device", n)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM device_links_v3 WHERE id = ?`, f.link.ID); n != 0 {
		t.Fatal("the cancelled link context remains")
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'device.revoked' AND payload_json LIKE ?`, "%"+deviceID+"%"); n != 1 {
		t.Fatalf("device.revoked events = %d, want 1", n)
	}
	// The source device is untouched, and a second prune changes nothing.
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, f.owner.Device.ID); n != 1 {
		t.Fatal("the source device was revoked")
	}
	if _, err := f.store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'device.revoked' AND payload_json LIKE ?`, "%"+deviceID+"%"); n != 1 {
		t.Fatalf("a second prune queued %d device.revoked events, want 1", n)
	}
}

// A completed link keeps its device after its deadline: the prune only ends
// links that never produced a session.
func TestCompletedDeviceLinkV3KeepsItsDeviceAfterTheDeadline(t *testing.T) {
	f := newV3Fixture(t)
	ctx := context.Background()
	f.complete(t)
	if _, err := f.store.db.ExecContext(ctx, `UPDATE device_links_v3 SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Second)), f.link.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, f.reservation.DeviceID); n != 1 {
		t.Fatal("a completed link's device was revoked by the prune")
	}
}
