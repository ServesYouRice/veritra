package storage

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
)

// TASK-201 (C-5be3e65b2883, D100/D114): approval creates and announces the
// device, but the link cannot be consumed once expires_at passes. The
// operational prune cancels such a link: the device is revoked, its unclaimed
// key packages are deleted and the link is revoked, so no active device is
// left without a way to get a session. (VAL-253)
func TestApprovedDeviceLinkNearExpiryDoesNotOrphanDevice(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{})
	owner := createTestOwner(t, ctx, store)
	link, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute, testLinkLocator(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveDeviceLinkEnrollment(ctx, link.Code); err != nil {
		t.Fatal(err)
	}
	_, claimTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	transcript := bytes.Repeat([]byte{4}, 32)
	if _, err := store.ClaimDeviceLink(ctx, link.Code, "Tablet", []byte("tablet-key-package"), bytes.Repeat([]byte{2}, 32), transcript, bytes.Repeat([]byte{8}, 32), claimTokenHash, auth.HashToken("tablet-secret")); err != nil {
		t.Fatal(err)
	}
	_, device, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, transcript, bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE device_links SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Second)), link.ID); err != nil {
		t.Fatal(err)
	}

	_, sessionHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ConsumeApprovedDeviceLink(ctx, link.ID, claimTokenHash, sessionHash, time.Now().Add(time.Hour)); !errors.Is(err, ErrDeviceLinkInvalid) {
		t.Fatalf("consume after expiry: %v, want ErrDeviceLinkInvalid", err)
	}
	// Until the prune runs the characterization holds: consume fails.
	if _, err := store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	var active, keyPackages int
	var linkState string
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, device.ID).Scan(&active); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ? AND claimed_at IS NULL`, device.ID).Scan(&keyPackages); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT state FROM device_links WHERE id = ?`, link.ID).Scan(&linkState); err != nil {
		t.Fatal(err)
	}
	if active != 0 || keyPackages != 0 || linkState != "revoked" {
		t.Fatalf("after prune: active devices=%d key packages=%d link=%s, want 0, 0, revoked", active, keyPackages, linkState)
	}
	var events int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'device.revoked' AND payload_json LIKE ?`, "%"+device.ID+"%").Scan(&events); err != nil || events != 1 {
		t.Fatalf("device.revoked events=%d err=%v", events, err)
	}
}

// An approved link still inside its window keeps its device: the prune only
// cancels links that can no longer be consumed.
func TestPruneKeepsApprovedDeviceLinkInsideWindow(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{})
	owner := createTestOwner(t, ctx, store)
	link, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute, testLinkLocator(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveDeviceLinkEnrollment(ctx, link.Code); err != nil {
		t.Fatal(err)
	}
	_, claimTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	transcript := bytes.Repeat([]byte{4}, 32)
	if _, err := store.ClaimDeviceLink(ctx, link.Code, "Tablet", []byte("tablet-key-package"), bytes.Repeat([]byte{2}, 32), transcript, bytes.Repeat([]byte{8}, 32), claimTokenHash, auth.HashToken("tablet-secret")); err != nil {
		t.Fatal(err)
	}
	_, device, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, transcript, bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	_, sessionHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ConsumeApprovedDeviceLink(ctx, link.ID, claimTokenHash, sessionHash, time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("consume inside the window after a prune: %v", err)
	}
	var active int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, device.ID).Scan(&active); err != nil || active != 1 {
		t.Fatalf("active=%d err=%v", active, err)
	}
}

func approvedLinkFixture(t *testing.T, ctx context.Context, store *Store, owner AccountDevice, ttl time.Duration) (linkID, claimTokenHash, deviceID string) {
	t.Helper()
	link, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, ttl, testLinkLocator(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveDeviceLinkEnrollment(ctx, link.Code); err != nil {
		t.Fatal(err)
	}
	_, claimTokenHash, err = auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	transcript := bytes.Repeat([]byte{4}, 32)
	if _, err := store.ClaimDeviceLink(ctx, link.Code, "Tablet", []byte("tablet-key-package"), bytes.Repeat([]byte{2}, 32), transcript, bytes.Repeat([]byte{8}, 32), claimTokenHash, auth.HashToken("tablet-secret")); err != nil {
		t.Fatal(err)
	}
	_, device, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, transcript, bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	return link.ID, claimTokenHash, device.ID
}

// A consumed link's device stays active after the link expires and the prune
// runs, and repeated prunes of a cancelled link emit one event only.
func TestPruneNeverRevokesConsumedLinkDeviceAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{})
	owner := createTestOwner(t, ctx, store)
	linkID, claimHash, deviceID := approvedLinkFixture(t, ctx, store, owner, time.Minute)
	_, sessionHash, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ConsumeApprovedDeviceLink(ctx, linkID, claimHash, sessionHash, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE device_links SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Second)), linkID); err != nil {
		t.Fatal(err)
	}
	// A second, expired and unconsumed link.
	link2, _, device2 := approvedLinkFixture(t, ctx, store, owner, time.Minute)
	if _, err := store.db.ExecContext(ctx, `UPDATE device_links SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Second)), link2); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if _, err := store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	var active, sessions, state2Events int
	var state string
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, deviceID).Scan(&active); err != nil || active != 1 {
		t.Fatalf("consumed link device active=%d err=%v", active, err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sessions WHERE device_id = ?`, deviceID).Scan(&sessions); err != nil || sessions != 1 {
		t.Fatalf("consumed link device sessions=%d err=%v", sessions, err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT state FROM device_links WHERE id = ?`, linkID).Scan(&state); err != nil || state != "consumed" {
		t.Fatalf("consumed link state=%s err=%v", state, err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'device.revoked' AND payload_json LIKE ?`, "%"+device2+"%").Scan(&state2Events); err != nil || state2Events != 1 {
		t.Fatalf("expired link device.revoked events=%d err=%v", state2Events, err)
	}
}

// A device revoked by hand before its link is cancelled gets no second event.
func TestPruneSkipsAlreadyRevokedLinkDevice(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{})
	owner := createTestOwner(t, ctx, store)
	linkID, _, deviceID := approvedLinkFixture(t, ctx, store, owner, time.Minute)
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET revoked_at = ? WHERE id = ?`, nowString(), deviceID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE device_links SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Second)), linkID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.PruneOperationalRows(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	var events int
	var state string
	store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'device.revoked' AND payload_json LIKE ?`, "%"+deviceID+"%").Scan(&events)
	store.db.QueryRowContext(ctx, `SELECT state FROM device_links WHERE id = ?`, linkID).Scan(&state)
	if events != 0 || state != "revoked" {
		t.Fatalf("events=%d state=%s, want 0, revoked", events, state)
	}
}
