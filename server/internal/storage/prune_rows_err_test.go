package storage

import (
	"errors"
	"testing"
)

func TestScanStorageKeysSurfacesIterationFailure(t *testing.T) {
	boom := errors.New("disk I/O error")
	rows := &fakeRows{values: []string{"k1"}, failure: boom}
	if keys, err := scanStorageKeys(rows); !errors.Is(err, boom) || keys != nil || rows.closed != 1 {
		t.Fatalf("keys = %v, err = %v, closed = %d, want the failure and closed rows", keys, err, rows.closed)
	}
	keys, err := scanStorageKeys(&fakeRows{values: []string{"a", "b"}})
	if err != nil || len(keys) != 2 {
		t.Fatalf("healthy: keys = %v, err = %v", keys, err)
	}
}
