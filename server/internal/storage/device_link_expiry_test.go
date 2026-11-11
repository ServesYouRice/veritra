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
