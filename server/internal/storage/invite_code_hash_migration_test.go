package storage

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

// Migration 0094 keeps only SHA-256 of each registration invite code. Codes
// handed out before it still register, nothing in the table (or in a backup
// taken after it) holds a code, the unique index now covers the hashes, and an
// enrollment reserved before the upgrade survives it.
func TestInviteCodeHashMigrationKeepsOldCodesWorkingWithoutPlaintext(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0093")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	owner := createTestOwner(t, ctx, store)

	codes := map[string]string{}
	for _, id := range []string{"inv_live", "inv_revoked", "inv_spare"} {
		code, err := domain.NewInviteCode()
		if err != nil {
			t.Fatal(err)
		}
		codes[id] = code
	}
	insert := func(id string, maxUses int, revokedAt any) {
		t.Helper()
		if _, err := store.db.ExecContext(ctx, `INSERT INTO invites(id, code, created_by, max_uses, created_at, revoked_at) VALUES(?, ?, ?, ?, ?, ?)`,
			id, codes[id], owner.Account.ID, maxUses, nowString(), revokedAt); err != nil {
			t.Fatal(err)
		}
	}
	insert("inv_live", 3, nil)
	insert("inv_revoked", 1, nowString())
	insert("inv_spare", 1, nil)
	liveID := "inv_live"
	// Reserved before the upgrade; the migration must not drop it (a table
	// rebuild of invites would cascade-delete it).
	pending, err := store.createEnrollmentReservation(ctx, "register", &liveID)
	if err != nil {
		t.Fatal(err)
	}

	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatalf("second migrate: %v", err)
	}

	// The plaintext column is gone; only hashes remain.
	columns := tableColumns(t, ctx, store, "invites")
	if columns["code"] || !columns["code_hash"] {
		t.Fatalf("invites columns after 0094: %v", columns)
	}
	for id, code := range codes {
		var stored string
		if err := store.db.QueryRowContext(ctx, `SELECT code_hash FROM invites WHERE id = ?`, id).Scan(&stored); err != nil {
			t.Fatal(err)
		}
		if stored != auth.HashToken(code) {
			t.Fatalf("%s stored %q; want the hash of its code", id, stored)
		}
	}
	assertNoInviteCodeInRows(t, ctx, store, codes)

	// The unique index survived the rename and now covers code_hash.
	if !uniqueIndexOn(t, ctx, store, "invites", "code_hash") {
		t.Fatal("invites has no unique index on code_hash")
	}
	if _, err := store.db.ExecContext(ctx, `INSERT INTO invites(id, code_hash, created_by, created_at) VALUES('inv_dup', ?, ?, ?)`,
		auth.HashToken(codes["inv_live"]), owner.Account.ID, nowString()); err == nil {
		t.Fatal("a duplicate code_hash was accepted")
	}

	// The reservation made before the upgrade completes with the old code.
	if _, err := store.RegisterWithInvite(ctx, RegisterInput{
		EnrollmentReservationID: pending.ID, InviteCode: codes["inv_live"],
		Username: "beforeupgrade", PasswordHash: "hash", DeviceName: "phone", KeyPackage: []byte("key-a"),
	}); err != nil {
		t.Fatalf("register with a pre-upgrade reservation: %v", err)
	}
	// A new reservation and registration with the same old code, padded the
	// way a pasted code may be.
	reservation, err := store.ReserveRegistrationEnrollment(ctx, "  "+codes["inv_live"]+"\n")
	if err != nil {
		t.Fatalf("reserve with an old code: %v", err)
	}
	if _, err := store.RegisterWithInvite(ctx, RegisterInput{
		EnrollmentReservationID: reservation.ID, InviteCode: codes["inv_live"],
		Username: "afterupgrade", PasswordHash: "hash", DeviceName: "phone", KeyPackage: []byte("key-b"),
	}); err != nil {
		t.Fatalf("register with an old code: %v", err)
	}
	var uses int
	if err := store.db.QueryRowContext(ctx, `SELECT uses FROM invites WHERE id = 'inv_live'`).Scan(&uses); err != nil || uses != 2 {
		t.Fatalf("uses=%d err=%v; want 2", uses, err)
	}
	// Revocation still holds, and the hash itself is not a code.
	for _, code := range []string{codes["inv_revoked"], auth.HashToken(codes["inv_spare"]), ""} {
		if _, err := store.ReserveRegistrationEnrollment(ctx, code); !errors.Is(err, ErrInviteInvalid) {
			t.Fatalf("reserve with %q: %v; want ErrInviteInvalid", code, err)
		}
	}

	// Listing never carries a code, for old invites or new ones.
	fresh, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil || fresh.Code == "" {
		t.Fatalf("create invite: %+v %v", fresh, err)
	}
	codes["fresh"] = fresh.Code
	listed, err := store.ListInvites(ctx, owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 3 {
		t.Fatalf("listed %d invites; want 3 (live, spare, fresh)", len(listed))
	}
	for _, invite := range listed {
		if invite.Code != "" {
			t.Fatalf("listed invite %s carries a code", invite.ID)
		}
	}
	assertNoInviteCodeInRows(t, ctx, store, codes)

	// A backup taken after the upgrade holds no code.
	backup := filepath.Join(t.TempDir(), "backup.db")
	if err := store.BackupTo(ctx, backup); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(backup)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte(auth.HashToken(codes["inv_live"]))) {
		t.Fatal("the backup scan misses a hash that is stored")
	}
	for id, code := range codes {
		if bytes.Contains(data, []byte(code)) {
			t.Fatalf("the backup holds the code of %s", id)
		}
	}
}

func tableColumns(t *testing.T, ctx context.Context, store *Store, table string) map[string]bool {
	t.Helper()
	rows, err := store.db.QueryContext(ctx, `SELECT name FROM pragma_table_info(?)`, table)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	columns := map[string]bool{}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		columns[name] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return columns
}

// uniqueIndexOn reports whether table has a unique index over column alone.
func uniqueIndexOn(t *testing.T, ctx context.Context, store *Store, table, column string) bool {
	t.Helper()
	rows, err := store.db.QueryContext(ctx, `
		SELECT l.name FROM pragma_index_list(?) AS l
		WHERE l."unique" = 1
		  AND (SELECT COUNT(*) FROM pragma_index_info(l.name)) = 1
		  AND (SELECT name FROM pragma_index_info(l.name)) = ?`, table, column)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	found := rows.Next()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return found
}

// assertNoInviteCodeInRows fails when any text value of any invites row
// contains one of codes.
func assertNoInviteCodeInRows(t *testing.T, ctx context.Context, store *Store, codes map[string]string) {
	t.Helper()
	rows, err := store.db.QueryContext(ctx, `SELECT id, code_hash, created_by, COALESCE(expires_at, ''), created_at, COALESCE(revoked_at, '') FROM invites`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		values := make([]string, 6)
		pointers := make([]any, len(values))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err := rows.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		joined := strings.Join(values, "\x00")
		for id, code := range codes {
			if strings.Contains(joined, code) {
				t.Fatalf("invites row %s holds the code of %s", values[0], id)
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
}
