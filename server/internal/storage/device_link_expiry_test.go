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

// Characterization for TASK-201 (C-5be3e65b2883), which waits on the owner's
// choice of remedy (plan question section-27680a1f2c16710b211bbaf9/Q-002).
// Approval creates and announces the device; consuming the link still needs
// the original expires_at to be in the future. So a link approved but not
// consumed before it expires leaves an active device that the link can no
// longer give a session, and that still counts against the device limit.
// The device keeps the secret the claimant got at claim time, so a password
// sign-in with that device ID and secret still works. When Q-002 is decided,
// this test flips to assert the chosen remedy (VAL-253).
func TestApprovedDeviceLinkPastExpiryLeavesActiveDevice(t *testing.T) {
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
	var active, sessions int
	var secretHash string
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(MAX(auth_secret_hash), '') FROM devices WHERE id = ? AND revoked_at IS NULL`, device.ID).Scan(&active, &secretHash); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sessions WHERE device_id = ?`, device.ID).Scan(&sessions); err != nil {
		t.Fatal(err)
	}
	if active != 1 || sessions != 0 || secretHash != auth.HashToken("tablet-secret") {
		t.Fatalf("device after expiry: active=%d sessions=%d secret kept=%v", active, sessions, secretHash == auth.HashToken("tablet-secret"))
	}
	record, err := store.LoginRecord(ctx, owner.Account.Username, device.ID)
	if err != nil || record.DeviceAuthHash != auth.HashToken("tablet-secret") {
		t.Fatalf("password sign-in record for the linked device: %+v %v", record, err)
	}
}
