package storage

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/domain"
)

// K1 automatic backups (docs/designs/K1-automatic-backups.md, D91).
const (
	// BackupKindLegacy is an I45/VBK2 backup with a recovery token.
	BackupKindLegacy = 0
	// BackupKindK1 is a VHC1 kind-1 copy sealed to the recovery key.
	BackupKindK1 = 1
	// K1SupersededGrace keeps a replaced copy downloadable, so a restore
	// that is under way survives the owner device's next upload.
	K1SupersededGrace = 24 * time.Hour
	// K1RevokedRetention keeps a revoked device's newest copy: that copy is
	// what a user who lost the phone restores from.
	K1RevokedRetention = 90 * 24 * time.Hour
	// K1RevokedCopiesPerAccount caps the revoked devices' copies kept.
	K1RevokedCopiesPerAccount = 3
)

var (
	// ErrRecoveryKeyChanged: the upload names another rk_id than the
	// account's current recovery key (or the account has none).
	ErrRecoveryKeyChanged = errors.New("backup is sealed to another recovery key")
	// ErrBackupCounterStale: the counter is not above this device's last.
	ErrBackupCounterStale = errors.New("backup counter is not above the device's last")
)

// K1BackupUpload is one kind-1 copy whose ciphertext the blob store holds.
type K1BackupUpload struct {
	AccountID, DeviceID          string
	StorageKey, CiphertextSHA256 string
	SizeBytes                    int64
	ChunkDigests                 []byte
	RKID                         []byte
	Counter                      int64
}

// K1BackupMetadata is the stored metadata document of a kind-1 copy. The
// columns are what the server checks; the document is kept so the legacy
// key_derivation_metadata field stays filled.
func K1BackupMetadata(rkID []byte, counter int64) json.RawMessage {
	encoded, _ := json.Marshal(map[string]interface{}{
		"kind": BackupKindK1, "rk_id": base64.StdEncoding.EncodeToString(rkID), "counter": counter,
	})
	return encoded
}

// CreateK1Backup stores a device's new kind-1 copy and, in the same
// transaction, marks its previous copy superseded (deleting any copy
// superseded before that) and returns, in PrunedStorageKeys, the blobs it
// queued for deletion so the caller removes them at once. It refuses a copy sealed
// to another recovery key, a counter not above the device's last, and a copy
// beyond the account's backup allowance. Expired superseded and revoked
// copies of the account are pruned first, and their blobs queued.
func (s *Store) CreateK1Backup(ctx context.Context, in K1BackupUpload) (domain.BackupBlob, error) {
	if in.AccountID == "" || in.DeviceID == "" || in.StorageKey == "" || len(in.RKID) != 16 ||
		in.Counter <= 0 || in.SizeBytes <= 0 {
		return domain.BackupBlob{}, ErrInvalidInput
	}
	id, err := domain.NewID("backup")
	if err != nil {
		return domain.BackupBlob{}, err
	}
	now := time.Now().UTC()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	defer tx.Rollback()

	// The device must be the account's and not revoked (a revoked device has
	// no session, so this only guards a race with the revocation).
	var revokedAt sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT revoked_at FROM devices WHERE id = ? AND account_id = ?`, in.DeviceID, in.AccountID).Scan(&revokedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.BackupBlob{}, ErrForbidden
		}
		return domain.BackupBlob{}, err
	}
	if revokedAt.Valid {
		return domain.BackupBlob{}, ErrForbidden
	}
	var currentRKID []byte
	switch err := tx.QueryRowContext(ctx, `SELECT rk_id FROM account_recovery_keys WHERE account_id = ?`, in.AccountID).Scan(&currentRKID); {
	case errors.Is(err, sql.ErrNoRows):
		return domain.BackupBlob{}, ErrRecoveryKeyChanged
	case err != nil:
		return domain.BackupBlob{}, err
	}
	if !bytes.Equal(currentRKID, in.RKID) {
		return domain.BackupBlob{}, ErrRecoveryKeyChanged
	}
	var lastCounter sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT counter FROM k1_backup_counters WHERE device_id = ?`, in.DeviceID).Scan(&lastCounter); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return domain.BackupBlob{}, err
	}
	if lastCounter.Valid && in.Counter <= lastCounter.Int64 {
		return domain.BackupBlob{}, ErrBackupCounterStale
	}
	removed, err := pruneK1BackupsTx(ctx, tx, in.AccountID, now, -1)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	// At most two copies per device (design change 3): the copy superseded
	// before goes now, even inside its grace, so a loop of uploads cannot
	// pile up copies the allowance does not count.
	older, err := deleteBackupRowsTx(ctx, tx, `SELECT id, storage_key FROM backup_blobs
		WHERE account_id = ? AND device_id = ? AND kind = 1 AND superseded_at IS NOT NULL`, in.AccountID, in.DeviceID)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	removed = append(removed, older...)
	if err := s.enforceK1BackupAllowance(ctx, tx, in.AccountID, in.DeviceID, in.SizeBytes); err != nil {
		return domain.BackupBlob{}, err
	}
	stamp := formatTime(now)
	if _, err := tx.ExecContext(ctx, `UPDATE backup_blobs SET superseded_at = ?
		WHERE account_id = ? AND device_id = ? AND kind = 1 AND superseded_at IS NULL`, stamp, in.AccountID, in.DeviceID); err != nil {
		return domain.BackupBlob{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO k1_backup_counters(device_id, counter) VALUES(?, ?)
		ON CONFLICT(device_id) DO UPDATE SET counter = excluded.counter`, in.DeviceID, in.Counter); err != nil {
		return domain.BackupBlob{}, err
	}
	metadata := K1BackupMetadata(in.RKID, in.Counter)
	if _, err := tx.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, device_id, storage_key, ciphertext_sha256,
		size_bytes, key_derivation_metadata_json, created_at, recovery_next_offset, chunk_digests, kind, rk_id, counter)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 1, ?, ?)`,
		id, in.AccountID, in.DeviceID, in.StorageKey, in.CiphertextSHA256, in.SizeBytes, string(metadata), stamp,
		nullableBytes(in.ChunkDigests), in.RKID, in.Counter); err != nil {
		return domain.BackupBlob{}, err
	}
	backup, err := scanBackupWithK1(tx.QueryRowContext(ctx, `SELECT `+backupColumnsK1+` FROM backup_blobs WHERE id = ?`, id))
	if err != nil {
		return domain.BackupBlob{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.BackupBlob{}, err
	}
	backup.PrunedStorageKeys = removed
	return backup, nil
}

// enforceK1BackupAllowance checks the account's backup allowance (D91): the
// current copies of its other active devices plus the new one. This device's
// copy being replaced, superseded copies (gone within a day) and revoked
// devices' copies (at most three, for 90 days) do not count. The instance
// total counts every blob, as for attachments.
func (s *Store) enforceK1BackupAllowance(ctx context.Context, tx *sql.Tx, accountID, deviceID string, incoming int64) error {
	var current, instanceUsage int64
	if err := tx.QueryRowContext(ctx, `SELECT
		COALESCE((SELECT SUM(b.size_bytes) FROM backup_blobs b JOIN devices d ON d.id = b.device_id
			WHERE b.account_id = ? AND b.kind = 1 AND b.superseded_at IS NULL AND d.revoked_at IS NULL AND b.device_id <> ?), 0),
		(SELECT size_bytes FROM blob_usage_instance WHERE id = 1)`, accountID, deviceID).Scan(&current, &instanceUsage); err != nil {
		return err
	}
	if incoming < 0 || current > s.limits.BackupAllowanceBytes-incoming || instanceUsage > s.limits.InstanceStorageBytes-incoming {
		return s.refuse(admission.Storage, ErrStorageQuota)
	}
	return nil
}

// k1PruneCondition selects the kind-1 rows a prune deletes: superseded more
// than a day ago, a revoked device's copy 90 days after the revocation, and
// revoked devices' copies beyond the account's newest three.
const k1PruneCondition = `b.kind = 1 AND (
	b.superseded_at < ?1
	OR EXISTS (SELECT 1 FROM devices d WHERE d.id = b.device_id AND d.revoked_at IS NOT NULL AND d.revoked_at < ?2)
	OR (b.superseded_at IS NULL AND EXISTS (SELECT 1 FROM devices d WHERE d.id = b.device_id AND d.revoked_at IS NOT NULL)
		AND (SELECT COUNT(*) FROM backup_blobs o JOIN devices od ON od.id = o.device_id
			WHERE o.account_id = b.account_id AND o.kind = 1 AND o.superseded_at IS NULL AND od.revoked_at IS NOT NULL
			AND (o.created_at > b.created_at OR (o.created_at = b.created_at AND o.id > b.id))) >= ?3)
)`

// pruneK1BackupsTx deletes the kind-1 rows k1PruneCondition selects, for one
// account (accountID set) or the whole instance, at most limit rows (limit
// < 0: all), and queues their blobs for deletion in the same transaction.
func pruneK1BackupsTx(ctx context.Context, tx *sql.Tx, accountID string, now time.Time, limit int) ([]string, error) {
	query := `SELECT b.id, b.storage_key FROM backup_blobs b WHERE ` + k1PruneCondition
	args := []interface{}{formatTime(now.Add(-K1SupersededGrace)), formatTime(now.Add(-K1RevokedRetention)), K1RevokedCopiesPerAccount}
	if accountID != "" {
		query += ` AND b.account_id = ?4`
		args = append(args, accountID)
	}
	query += ` ORDER BY b.created_at, b.id`
	if limit >= 0 {
		query += ` LIMIT ` + strconv.Itoa(limit)
	}
	return deleteBackupRowsTx(ctx, tx, query, args...)
}

// deleteBackupRowsTx deletes the backup rows query returns (id, storage_key)
// and queues each blob through the deletion queue (reconcileBlobDeletions).
func deleteBackupRowsTx(ctx context.Context, tx *sql.Tx, query string, args ...interface{}) ([]string, error) {
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	type victim struct{ id, storageKey string }
	var victims []victim
	for rows.Next() {
		var v victim
		if err := rows.Scan(&v.id, &v.storageKey); err != nil {
			rows.Close()
			return nil, err
		}
		victims = append(victims, v)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(victims))
	for _, v := range victims {
		if _, err := tx.ExecContext(ctx, `DELETE FROM backup_blobs WHERE id = ?`, v.id); err != nil {
			return nil, err
		}
		if err := enqueueBlobDeletion(ctx, tx, v.storageKey); err != nil {
			return nil, err
		}
		keys = append(keys, v.storageKey)
	}
	return keys, nil
}

// PruneK1Backups runs the K1 prune for the whole instance, 500 rows at a
// time, from the retention sweeper. An upload prunes its own account too.
func (s *Store) PruneK1Backups(ctx context.Context, now time.Time) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	removed, err := pruneK1BackupsTx(ctx, tx, "", now.UTC(), 500)
	if err != nil {
		return 0, err
	}
	return int64(len(removed)), tx.Commit()
}

// deleteK1BackupsForKeySwapTx runs inside a recovery-key change: every
// kind-1 copy sealed to another key goes, except revoked devices' copies.
// Those are what a user who just recovered (and still holds the old key)
// restores from; the prune keeps them 90 days at most (design, server
// change 6).
func deleteK1BackupsForKeySwapTx(ctx context.Context, tx *sql.Tx, accountID string, newRKID []byte, now time.Time) error {
	if _, err := deleteBackupRowsTx(ctx, tx, `SELECT b.id, b.storage_key FROM backup_blobs b
		WHERE b.account_id = ? AND b.kind = 1 AND b.rk_id <> ?
		AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.id = b.device_id AND d.revoked_at IS NOT NULL)`, accountID, newRKID); err != nil {
		return err
	}
	_, err := pruneK1BackupsTx(ctx, tx, accountID, now, -1)
	return err
}

// backupColumnsK1 is the backup row with the K1 fields and its device's
// name and revocation, for scanBackupWithK1.
const backupColumnsK1 = `id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes,
	key_derivation_metadata_json, created_at, chunk_digests, kind, rk_id, counter, superseded_at,
	(SELECT name FROM devices WHERE devices.id = backup_blobs.device_id),
	(SELECT revoked_at IS NOT NULL FROM devices WHERE devices.id = backup_blobs.device_id)`

func scanBackupWithK1(row scanner) (domain.BackupBlob, error) {
	var digests, rkID []byte
	var kind int
	var counter sql.NullInt64
	var superseded, deviceName sql.NullString
	var revoked sql.NullBool
	backup, err := scanBackup(row, &digests, &kind, &rkID, &counter, &superseded, &deviceName, &revoked)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	backup.ChunkDigests = digests
	backup.Kind = kind
	backup.RKID = rkID
	if counter.Valid {
		value := counter.Int64
		backup.Counter = &value
	}
	backup.Superseded = superseded.Valid
	backup.DeviceName = deviceName.String
	backup.DeviceRevoked = revoked.Valid && revoked.Bool
	return backup, nil
}
