package storage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// fakeRows is a row iterator that can fail the way database/sql does: Next
// returns false at the failure, Err reports it, and Close returns nil.
type fakeRows struct {
	values  []string
	next    int
	failure error // reported by Err after the last value
	closed  int
	scanErr error
}

func (f *fakeRows) Next() bool {
	if f.next < len(f.values) {
		f.next++
		return true
	}
	return false
}

func (f *fakeRows) Scan(dest ...any) error {
	if f.scanErr != nil {
		return f.scanErr
	}
	*(dest[0].(*string)) = f.values[f.next-1]
	return nil
}

func (f *fakeRows) Err() error   { return f.failure }
func (f *fakeRows) Close() error { f.closed++; return nil }

func TestRowIteratorSurfacesErr(t *testing.T) {
	boom := errors.New("disk I/O error")
	rows := &fakeRows{values: []string{"a", "b"}, failure: boom}
	var seen []string
	err := eachRow(rows, func(rows rowIterator) error {
		var value string
		if err := rows.Scan(&value); err != nil {
			return err
		}
		seen = append(seen, value)
		return nil
	})
	if !errors.Is(err, boom) {
		t.Fatalf("eachRow err = %v, want the iteration failure", err)
	}
	if len(seen) != 2 || rows.closed != 1 {
		t.Fatalf("visited %v, closed %d times", seen, rows.closed)
	}

	visitErr := errors.New("bad row")
	rows = &fakeRows{values: []string{"a", "b"}}
	calls := 0
	err = eachRow(rows, func(rowIterator) error { calls++; return visitErr })
	if !errors.Is(err, visitErr) || calls != 1 || rows.closed != 1 {
		t.Fatalf("visit error: err = %v, calls = %d, closed = %d, want it returned after the first row with the rows closed", err, calls, rows.closed)
	}

	rows = &fakeRows{values: []string{"x"}}
	if err := eachRow(rows, func(rowIterator) error { return nil }); err != nil || rows.closed != 1 {
		t.Fatalf("healthy iteration: err = %v, closed = %d", err, rows.closed)
	}
}

func TestQuickCheckWithoutRowsFails(t *testing.T) {
	if err := checkQuickCheckRows(&fakeRows{}); err == nil {
		t.Fatal("a quick_check that returned nothing passed")
	}
	if err := checkQuickCheckRows(&fakeRows{failure: errors.New("interrupted")}); err == nil {
		t.Fatal("a quick_check that failed before its first row passed")
	}
	if err := checkQuickCheckRows(&fakeRows{values: []string{"ok"}}); err != nil {
		t.Fatalf("a passing quick_check: %v", err)
	}
	if err := checkQuickCheckRows(&fakeRows{values: []string{"ok", "row 3 missing from index idx"}}); err == nil {
		t.Fatal("a quick_check that reported a problem passed")
	}
	if err := checkQuickCheckRows(&fakeRows{values: []string{"ok"}, scanErr: errors.New("scan")}); err == nil {
		t.Fatal("a quick_check row that could not be read passed")
	}
}

func TestDatabaseFileValidationAndReferencesOnAHealthyDatabase(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	owner := createTestOwner(t, ctx, store)
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_healthy_backup", "00000000000000000000000000000000000000000000000000000000000000aa", 5, []byte(`{"state_counter":1}`), make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	copyPath := filepath.Join(t.TempDir(), "copy.db")
	if err := store.BackupTo(ctx, copyPath); err != nil {
		t.Fatal(err)
	}
	store.Close()
	if err := ValidateDatabaseFile(ctx, copyPath); err != nil {
		t.Fatalf("validate a healthy copy: %v", err)
	}
	references, migrations, err := ListDatabaseBlobReferences(ctx, copyPath)
	if err != nil || len(references) != 1 || references[0].StorageKey != "blob_healthy_backup" || len(migrations) == 0 {
		t.Fatalf("references = %#v, migrations = %d, err = %v", references, len(migrations), err)
	}
	for i := 1; i < len(migrations); i++ {
		if migrations[i-1] >= migrations[i] {
			t.Fatalf("migrations out of order: %v", migrations)
		}
	}
	// A file that is not a database fails validation.
	garbage := filepath.Join(t.TempDir(), "garbage.db")
	if err := os.WriteFile(garbage, []byte("this is not a sqlite database at all, just text"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateDatabaseFile(ctx, garbage); err == nil {
		t.Fatal("validated a file that is not a database")
	}
}
