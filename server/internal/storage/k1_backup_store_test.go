package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
)

var (
	k1TestRK    = bytes.Repeat([]byte{9}, 16) // claimTestRecovery's rk_id
	k1TestNewRK = bytes.Repeat([]byte{7}, 16)
)

func k1Upload(account AccountDevice, deviceID, key string, size, counter int64, rkID []byte) K1BackupUpload {
	return K1BackupUpload{AccountID: account.Account.ID, DeviceID: deviceID, StorageKey: key,
		CiphertextSHA256: strings.Repeat("b", 64), SizeBytes: size, RKID: rkID, Counter: counter}
}

func setK1TestRecoveryKey(t *testing.T, ctx context.Context, store *Store, accountID string, rkID []byte) {
	t.Helper()
	if _, err := store.SetRecoveryKey(ctx, accountID, testRecoveryAuthKey, rkID); err != nil {
		t.Fatalf("set recovery key: %v", err)
	}
}

func k1Rows(t *testing.T, ctx context.Context, store *Store, accountID string) map[string]bool {
	t.Helper()
	rows, err := store.db.QueryContext(ctx, `SELECT storage_key, superseded_at IS NOT NULL FROM backup_blobs WHERE account_id = ? AND kind = 1`, accountID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var key string
		var superseded bool
		if err := rows.Scan(&key, &superseded); err != nil {
			t.Fatal(err)
		}
		out[key] = superseded
	}
	return out
}

func queuedBlobDeletion(t *testing.T, ctx context.Context, store *Store, key string) bool {
	t.Helper()
	return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM blob_deletion_queue WHERE storage_key = ?`, key) == 1
}

func ageK1Row(t *testing.T, ctx context.Context, store *Store, key string, superseded time.Time) {
	t.Helper()
	if _, err := store.db.ExecContext(ctx, `UPDATE backup_blobs SET superseded_at = ? WHERE storage_key = ?`, formatTime(superseded), key); err != nil {
		t.Fatal(err)
	}
}

func TestK1UploadChecksKeyCounterAndDevice(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	dev := owner.Device.ID

	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_nokey", 10, 1, k1TestRK)); !errors.Is(err, ErrRecoveryKeyChanged) {
		t.Fatalf("no recovery key: err = %v, want %v", err, ErrRecoveryKeyChanged)
	}
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestRK)
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_otherkey", 10, 1, k1TestNewRK)); !errors.Is(err, ErrRecoveryKeyChanged) {
		t.Fatalf("other rk_id: err = %v, want %v", err, ErrRecoveryKeyChanged)
	}
	first, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_first", 10, 5, k1TestRK))
	if err != nil {
		t.Fatalf("first copy: %v", err)
	}
	if first.Kind != BackupKindK1 || first.Counter == nil || *first.Counter != 5 || !bytes.Equal(first.RKID, k1TestRK) || first.Superseded {
		t.Fatalf("first copy = %+v", first)
	}
	for _, counter := range []int64{5, 4} {
		if _, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_stale", 10, counter, k1TestRK)); !errors.Is(err, ErrBackupCounterStale) {
			t.Fatalf("counter %d: err = %v, want %v", counter, err, ErrBackupCounterStale)
		}
	}
	// Gaps are fine (the app commits the counter before the upload).
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_second", 10, 9, k1TestRK)); err != nil {
		t.Fatalf("second copy: %v", err)
	}
	if got := k1Rows(t, ctx, store, owner.Account.ID); len(got) != 2 || !got["k1_first"] || got["k1_second"] {
		t.Fatalf("rows = %v, want first superseded and second current", got)
	}
	// Another device has its own counter sequence.
	addTestDevice(t, ctx, store, owner.Account.ID, "dev_k1_other")
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, "dev_k1_other", "k1_other_dev", 10, 1, k1TestRK)); err != nil {
		t.Fatalf("other device's first copy: %v", err)
	}
	// A revoked device, or one of another account, cannot upload.
	if err := store.RevokeDevice(ctx, owner.Account.ID, "dev_k1_other"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, "dev_k1_other", "k1_revoked_dev", 10, 2, k1TestRK)); !errors.Is(err, ErrForbidden) {
		t.Fatalf("revoked device: err = %v, want %v", err, ErrForbidden)
	}
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, "dev_nobody", "k1_unknown_dev", 10, 1, k1TestRK)); !errors.Is(err, ErrForbidden) {
		t.Fatalf("unknown device: err = %v, want %v", err, ErrForbidden)
	}
	// Legacy uploads still read their own counter, never a K1 one.
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, dev, "legacy_after_k1", strings.Repeat("c", 64), 10, json.RawMessage(`{"state_counter":1}`), bytes.Repeat([]byte{1}, 32)); err != nil {
		t.Fatalf("legacy upload next to K1 copies: %v", err)
	}
}

func TestK1SupersededCopyKeptForADayThenPruned(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestRK)
	dev := owner.Device.ID
	first, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_day1", 10, 1, k1TestRK))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_day2", 10, 2, k1TestRK)); err != nil {
		t.Fatal(err)
	}
	// Still downloadable, and listed as superseded.
	got, err := store.BackupForAccount(ctx, first.ID, owner.Account.ID)
	if err != nil || !got.Superseded || got.StorageKey != "k1_day1" {
		t.Fatalf("superseded copy within the grace: %+v, %v", got, err)
	}
	list, err := store.ListBackups(ctx, owner.Account.ID, 10)
	if err != nil || len(list) != 2 || !list[1].Superseded || list[0].Superseded || list[0].DeviceName == "" {
		t.Fatalf("list = %+v, %v", list, err)
	}
	// The sweeper leaves it alone inside the grace.
	if n, err := store.PruneK1Backups(ctx, time.Now()); err != nil || n != 0 {
		t.Fatalf("prune inside the grace = %d, %v", n, err)
	}
	// Past a day the next upload deletes it and queues its blob.
	ageK1Row(t, ctx, store, "k1_day1", time.Now().Add(-K1SupersededGrace-time.Minute))
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, dev, "k1_day3", 10, 3, k1TestRK)); err != nil {
		t.Fatal(err)
	}
	if got := k1Rows(t, ctx, store, owner.Account.ID); len(got) != 2 || got["k1_day3"] || !got["k1_day2"] {
		t.Fatalf("rows after the third upload = %v", got)
	}
	if !queuedBlobDeletion(t, ctx, store, "k1_day1") {
		t.Fatal("the pruned copy's blob was not queued for deletion")
	}
	// The sweeper does the same without an upload.
	ageK1Row(t, ctx, store, "k1_day2", time.Now().Add(-K1SupersededGrace-time.Minute))
	if n, err := store.PruneK1Backups(ctx, time.Now()); err != nil || n != 1 || !queuedBlobDeletion(t, ctx, store, "k1_day2") {
		t.Fatalf("sweeper prune = %d, %v", n, err)
	}
}

func TestK1AllowanceIsSeparateAndCountsAReplacementOnce(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestRK)
	full := int64(config.MaxBackupCiphertext)
	if store.Limits().BackupAllowanceBytes != 2*full {
		t.Fatalf("allowance = %d", store.Limits().BackupAllowanceBytes)
	}
	addTestDevice(t, ctx, store, owner.Account.ID, "dev_k1_b")
	addTestDevice(t, ctx, store, owner.Account.ID, "dev_k1_c")
	// Two full-size devices fit.
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, owner.Device.ID, "k1_a1", full, 1, k1TestRK)); err != nil {
		t.Fatalf("first full copy: %v", err)
	}
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, "dev_k1_b", "k1_b1", full, 1, k1TestRK)); err != nil {
		t.Fatalf("second full copy: %v", err)
	}
	// A replacement counts once: the copy it replaces is not counted.
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, owner.Device.ID, "k1_a2", full, 2, k1TestRK)); err != nil {
		t.Fatalf("replacement at the allowance: %v", err)
	}
	// A third device does not fit.
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, "dev_k1_c", "k1_c1", 1, 1, k1TestRK)); !errors.Is(err, ErrStorageQuota) {
		t.Fatalf("third device: err = %v, want %v", err, ErrStorageQuota)
	}
	// K1 copies use neither the attachment quota nor the blob count.
	if n := testRowCount(t, ctx, store, `SELECT COALESCE((SELECT size_bytes FROM blob_usage_accounts WHERE account_id = ?), 0)`, owner.Account.ID); n != 0 {
		t.Fatalf("account usage = %d, want 0", n)
	}
	if n := testRowCount(t, ctx, store, `SELECT size_bytes FROM blob_usage_instance WHERE id = 1`); int64(n) != 3*full {
		t.Fatalf("instance usage = %d, want %d", n, 3*full)
	}
	// A revoked device's copy leaves the allowance (it is kept apart).
	if err := store.RevokeDevice(ctx, owner.Account.ID, "dev_k1_b"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, "dev_k1_c", "k1_c2", full, 2, k1TestRK)); err != nil {
		t.Fatalf("device after a revocation: %v", err)
	}
	// Deleting a K1 row returns its bytes to the instance only.
	if _, err := store.DeleteBackup(ctx, mustBackupID(t, ctx, store, "k1_c2"), owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COALESCE((SELECT size_bytes FROM blob_usage_accounts WHERE account_id = ?), 0)`, owner.Account.ID); n != 0 {
		t.Fatalf("account usage after a delete = %d, want 0", n)
	}
}

func mustBackupID(t *testing.T, ctx context.Context, store *Store, key string) string {
	t.Helper()
	var id string
	if err := store.db.QueryRowContext(ctx, `SELECT id FROM backup_blobs WHERE storage_key = ?`, key).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestK1RevokedCopiesKeptNinetyDaysAndAtMostThree(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestRK)
	base := time.Now().UTC().Add(-time.Hour)
	for i, id := range []string{"dev_r1", "dev_r2", "dev_r3", "dev_r4"} {
		addTestDevice(t, ctx, store, owner.Account.ID, id)
		if _, err := store.CreateK1Backup(ctx, k1Upload(owner, id, "k1_"+id, 10, 1, k1TestRK)); err != nil {
			t.Fatal(err)
		}
		if _, err := store.db.ExecContext(ctx, `UPDATE backup_blobs SET created_at = ? WHERE storage_key = ?`, formatTime(base.Add(time.Duration(i)*time.Minute)), "k1_"+id); err != nil {
			t.Fatal(err)
		}
		if err := store.RevokeDevice(ctx, owner.Account.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	// Four revoked copies: the oldest goes, the newest three stay.
	if n, err := store.PruneK1Backups(ctx, time.Now()); err != nil || n != 1 || !queuedBlobDeletion(t, ctx, store, "k1_dev_r1") {
		t.Fatalf("prune beyond three = %d, %v", n, err)
	}
	if got := k1Rows(t, ctx, store, owner.Account.ID); len(got) != 3 {
		t.Fatalf("rows = %v, want three", got)
	}
	// 90 days after its revocation a copy goes.
	if _, err := store.db.ExecContext(ctx, `UPDATE devices SET revoked_at = ? WHERE id = 'dev_r2'`, formatTime(time.Now().Add(-K1RevokedRetention-time.Hour))); err != nil {
		t.Fatal(err)
	}
	if n, err := store.PruneK1Backups(ctx, time.Now()); err != nil || n != 1 || !queuedBlobDeletion(t, ctx, store, "k1_dev_r2") {
		t.Fatalf("prune after 90 days = %d, %v", n, err)
	}
}

// Recover with no device left, then the forced new recovery key: the lost
// phone's copy (sealed to the old key) is still listed, while an active
// device's old-key copy goes with the swap.
func TestK1KeySwapAfterRecoveryKeepsTheLostPhonesCopy(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestRK)
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, owner.Device.ID, "k1_lost_phone", 10, 1, k1TestRK)); err != nil {
		t.Fatal(err)
	}
	claim := claimTestRecovery(t, ctx, store, owner, 0)
	completion, err := store.CompleteRecovery(ctx, claim.request.ID, claim.claimTokenHash, auth.HashToken("k1-session"))
	if err != nil || completion.State != RecoveryStateCompleted {
		t.Fatalf("complete recovery: %+v, %v", completion, err)
	}
	newDevice := claim.request.DeviceID
	// The recovered device backs up before the swap (old key), then the
	// forced swap happens.
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, newDevice, "k1_new_device_old_key", 10, 1, k1TestRK)); err != nil {
		t.Fatal(err)
	}
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestNewRK)
	got := k1Rows(t, ctx, store, owner.Account.ID)
	if _, ok := got["k1_lost_phone"]; !ok || len(got) != 1 {
		t.Fatalf("rows after the swap = %v, want only the lost phone's copy", got)
	}
	if !queuedBlobDeletion(t, ctx, store, "k1_new_device_old_key") {
		t.Fatal("the active device's old-key copy was not queued for deletion")
	}
	list, err := store.ListBackups(ctx, owner.Account.ID, 10)
	if err != nil || len(list) != 1 || !list[0].DeviceRevoked || !bytes.Equal(list[0].RKID, k1TestRK) {
		t.Fatalf("list after the swap = %+v, %v", list, err)
	}
	// The new device now backs up under the new key; its counter goes on.
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, newDevice, "k1_new_key", 10, 2, k1TestNewRK)); err != nil {
		t.Fatalf("upload under the new key: %v", err)
	}
	// Setting the same key again deletes nothing.
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestNewRK)
	if got := k1Rows(t, ctx, store, owner.Account.ID); len(got) != 2 {
		t.Fatalf("rows after re-setting the same key = %v", got)
	}
}

// Review blocker: a loop of uploads from one device keeps at most two copies
// (current and one superseded), whatever the grace says, and returns the
// replaced blobs so the route deletes them at once.
func TestK1UploadLoopKeepsTwoCopiesPerDevice(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestRK)
	full := int64(config.MaxBackupCiphertext)
	var pruned []string
	for i := int64(1); i <= 8; i++ {
		backup, err := store.CreateK1Backup(ctx, k1Upload(owner, owner.Device.ID, "k1_loop_"+strconv.FormatInt(i, 10), full, i, k1TestRK))
		if err != nil {
			t.Fatalf("upload %d: %v", i, err)
		}
		pruned = append(pruned, backup.PrunedStorageKeys...)
	}
	if got := k1Rows(t, ctx, store, owner.Account.ID); len(got) != 2 || !got["k1_loop_7"] || got["k1_loop_8"] {
		t.Fatalf("rows = %v, want loop_7 superseded and loop_8 current", got)
	}
	if n := testRowCount(t, ctx, store, `SELECT size_bytes FROM blob_usage_instance WHERE id = 1`); int64(n) != 2*full {
		t.Fatalf("instance usage = %d, want %d", n, 2*full)
	}
	if len(pruned) != 6 || pruned[0] != "k1_loop_1" || pruned[5] != "k1_loop_6" {
		t.Fatalf("pruned keys = %v", pruned)
	}
}

// The counter's high-water mark outlives the rows: after a swap deleted a
// device's copies, an old counter is still refused.
func TestK1CounterHighWaterSurvivesDeletes(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestRK)
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, owner.Device.ID, "k1_hw_5", 10, 5, k1TestRK)); err != nil {
		t.Fatal(err)
	}
	setK1TestRecoveryKey(t, ctx, store, owner.Account.ID, k1TestNewRK)
	if got := k1Rows(t, ctx, store, owner.Account.ID); len(got) != 0 {
		t.Fatalf("rows after the swap = %v", got)
	}
	for _, counter := range []int64{1, 5} {
		if _, err := store.CreateK1Backup(ctx, k1Upload(owner, owner.Device.ID, "k1_hw_old", 10, counter, k1TestNewRK)); !errors.Is(err, ErrBackupCounterStale) {
			t.Fatalf("counter %d after the swap: err = %v, want %v", counter, err, ErrBackupCounterStale)
		}
	}
	if _, err := store.CreateK1Backup(ctx, k1Upload(owner, owner.Device.ID, "k1_hw_6", 10, 6, k1TestNewRK)); err != nil {
		t.Fatalf("counter 6: %v", err)
	}
	// A K1 row without its key id cannot be written at all.
	if _, err := store.db.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, device_id, storage_key, size_bytes, key_derivation_metadata_json, created_at, kind, counter)
		VALUES('backup_nokey', ?, ?, 'k1_nokey_row', 1, '{}', ?, 1, 9)`, owner.Account.ID, owner.Device.ID, nowString()); err == nil {
		t.Fatal("a kind-1 row without rk_id was stored")
	}
}
