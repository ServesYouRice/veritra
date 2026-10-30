package storage

import (
	"context"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/migrations"
)

func TestDeviceLinkV2MigrationRetiresOnlyUnfinishedLegacyLinks(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	store, err := Open(ctx, config.Config{DataDir: dir, DatabasePath: filepath.Join(dir, "test.db"), StoragePath: filepath.Join(dir, "blobs")})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	old := fstest.MapFS{}
	entries, err := fs.ReadDir(migrations.FS, ".")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".sql") && entry.Name() < "0037" {
			data, err := fs.ReadFile(migrations.FS, entry.Name())
			if err != nil {
				t.Fatal(err)
			}
			old[entry.Name()] = &fstest.MapFile{Data: data}
		}
	}
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	owner := createTestOwner(t, ctx, store)
	sessionHash := auth.HashToken("migration-session-fixture")
	if err := store.CreateSession(ctx, sessionHash, owner.Account.ID, owner.Device.ID, time.Now().UTC().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"pending", "claimed", "approved", "consumed", "revoked"} {
		_, err := store.db.ExecContext(ctx, `INSERT INTO device_links(id, code, account_id, state, verification_code, protocol_version, created_at, expires_at) VALUES(?, ?, ?, ?, '', 'veritra-device-link-v1', ?, ?)`, state, state, owner.Account.ID, state, nowString(), "2030-01-01T00:00:00Z")
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	for _, original := range []string{"pending", "claimed", "approved", "consumed", "revoked"} {
		var state string
		if err := store.db.QueryRowContext(ctx, `SELECT state FROM device_links WHERE id = ?`, original).Scan(&state); err != nil {
			t.Fatal(err)
		}
		want := original
		if original == "pending" || original == "claimed" || original == "approved" {
			want = "revoked"
		}
		if state != want {
			t.Fatalf("%s became %s; want %s", original, state, want)
		}
	}
	var devices int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE account_id = ?`, owner.Account.ID).Scan(&devices); err != nil {
		t.Fatal(err)
	}
	if devices != 1 {
		t.Fatalf("migration changed devices: %d", devices)
	}
	principal, err := store.PrincipalByTokenHash(ctx, sessionHash)
	if err != nil || principal.DeviceID != owner.Device.ID {
		t.Fatalf("migration changed existing session: %v", err)
	}
}
