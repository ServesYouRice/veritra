package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// C-59172da4f1fb: the counter checked must be the counter stored. A key
// that only encoding/json matches ("STATE_COUNTER") would pass the check
// while the history query reads NULL from the stored document, so the next
// backup could reuse any counter.
func TestBackupCounterIsReadFromTheExactStoredKey(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	sha := strings.Repeat("a", 64)
	token := func(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_counter_5", sha, 32,
		json.RawMessage(`{"state_counter":5}`), token(1)); err != nil {
		t.Fatal(err)
	}
	for i, metadata := range []string{
		`{"STATE_COUNTER":6}`,
		`{"State_Counter":6}`,
		`{"state_counter":"6"}`,
		`{"state_counter":6.5}`,
		`{}`,
		`not json`,
	} {
		err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_bad_"+string(rune('a'+i)), sha, 32,
			json.RawMessage(metadata), token(byte(10+i)))
		if !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("metadata %s: err = %v, want %v", metadata, err, ErrInvalidInput)
		}
	}
	// A repeated key is judged by the value the history query will read.
	err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_repeated", sha, 32,
		json.RawMessage(`{"state_counter":6,"state_counter":7}`), token(30))
	if err == nil {
		var stored int64
		if err := store.db.QueryRowContext(ctx, `SELECT json_extract(key_derivation_metadata_json, '$.state_counter')
			FROM backup_blobs WHERE storage_key = 'blob_repeated'`).Scan(&stored); err != nil {
			t.Fatal(err)
		}
		if stored <= 5 {
			t.Fatalf("stored counter %d does not exceed the previous 5", stored)
		}
	} else if !errors.Is(err, ErrInvalidInput) {
		t.Fatal(err)
	}
	// The exact key still works and the counter keeps increasing.
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_counter_9", sha, 32,
		json.RawMessage(`{"state_counter":9}`), token(40)); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_counter_8", sha, 32,
		json.RawMessage(`{"state_counter":8}`), token(41)); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("a lower counter after 9: err = %v, want %v", err, ErrInvalidInput)
	}
}
