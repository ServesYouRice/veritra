package storage

import (
	"context"
	"testing"
	"time"

	"private-messenger/server/migrations"
)

func TestMarkDeviceSeenStoresTheUTCDayOnce(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	owner := createTestOwner(t, ctx, store)
	if err := store.MarkDeviceSeen(ctx, owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	var seen string
	if err := store.db.QueryRowContext(ctx, `SELECT last_seen_at FROM devices WHERE id = ?`, owner.Device.ID).Scan(&seen); err != nil {
		t.Fatal(err)
	}
	want := formatTime(time.Now().UTC().Truncate(24 * time.Hour))
	if seen != want {
		t.Fatalf("last_seen_at = %q, want the UTC day start %q", seen, want)
	}
	// An earlier day is refreshed; the same day is left alone.
	old := formatTime(time.Now().UTC().Add(-48 * time.Hour))
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET last_seen_at = ? WHERE id = ?`, old, owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.MarkDeviceSeen(ctx, owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT last_seen_at FROM devices WHERE id = ?`, owner.Device.ID).Scan(&seen); err != nil || seen != want {
		t.Fatalf("stale day not refreshed: %q err=%v", seen, err)
	}
	activity := SessionActivity{}
	if !activity.DeviceSeenDue(time.Now()) {
		t.Fatal("a never-seen device must be due")
	}
	today := time.Now().UTC().Truncate(24 * time.Hour)
	activity.DeviceLastSeenAt = &today
	if activity.DeviceSeenDue(time.Now()) {
		t.Fatal("a device already marked today must not be due")
	}
}

func TestLastSeenMigrationRoundsToTheDay(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0077")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	owner := createTestOwner(t, ctx, store)
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET last_seen_at = '2026-11-05T13:14:15.123456789Z' WHERE id = ?`, owner.Device.ID); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	var seen string
	if err := store.db.QueryRowContext(ctx, `SELECT last_seen_at FROM devices WHERE id = ?`, owner.Device.ID).Scan(&seen); err != nil {
		t.Fatal(err)
	}
	if seen != "2026-11-05T00:00:00.000000000Z" {
		t.Fatalf("migrated last_seen_at = %q", seen)
	}
}
