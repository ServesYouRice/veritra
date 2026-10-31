package storage

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/domain"
)

var ErrKeyPackageUnavailable = errors.New("an active conversation device has no available key package")

// ErrKeyPackageClaimLimit means the account has claimed as many key packages
// of one device as it may in KeyPackageClaimWindow.
var ErrKeyPackageClaimLimit = errors.New("this account has claimed too many key packages of a device today")

// KeyPackageClaimWindow is the span over which an account's claims on one
// device count against Limits.KeyPackageClaimsPerTarget.
const KeyPackageClaimWindow = 24 * time.Hour

// keyPackageClaimAllowed reports whether requesterAccountID may claim one
// more key package of targetDeviceID: it has claimed fewer than the limit
// from that device within the window, counting every device of the account.
// An account's claims on its own devices are not limited: they cannot take
// anything from anyone else, and adding a new device to all of an account's
// groups takes one claim per group.
func (s *Store) keyPackageClaimAllowed(ctx context.Context, q queryRower, targetDeviceID, targetAccountID, requesterAccountID string, now time.Time) (bool, error) {
	if targetAccountID == requesterAccountID {
		return true, nil
	}
	claimed, err := countRows(ctx, q, `
		SELECT COUNT(*) FROM device_key_packages kp
		JOIN devices claimer ON claimer.id = kp.claimed_by_device_id
		WHERE kp.device_id = ? AND kp.claimed_at IS NOT NULL AND kp.claimed_at > ?
		  AND claimer.account_id = ?`,
		targetDeviceID, formatTime(now.Add(-KeyPackageClaimWindow)), requesterAccountID)
	if err != nil {
		return false, err
	}
	return claimed < s.limits.KeyPackageClaimsPerTarget, nil
}

type NewDeviceKeyPackage struct {
	KeyPackage  []byte
	Ciphersuite string
	ExpiresAt   time.Time
}

const openMLSCiphersuite = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"

func insertInitialDeviceKeyPackage(ctx context.Context, tx *sql.Tx, deviceID string, keyPackage []byte, createdAt string) error {
	id, err := domain.NewID("kp")
	if err != nil {
		return err
	}
	created := parseTime(createdAt)
	_, err = tx.ExecContext(ctx, `INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at) VALUES(?, ?, ?, ?, ?, ?)`, id, deviceID, keyPackage, openMLSCiphersuite, createdAt, formatTime(created.Add(30*24*time.Hour)))
	return err
}

func (s *Store) PublishDeviceKeyPackages(ctx context.Context, deviceID string, packages []NewDeviceKeyPackage) ([]domain.DeviceKeyPackage, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var active bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM devices WHERE id = ? AND revoked_at IS NULL)`, deviceID).Scan(&active); err != nil {
		return nil, err
	}
	if !active {
		return nil, ErrForbidden
	}
	var available int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ? AND claimed_at IS NULL AND expires_at > ?`, deviceID, nowString()).Scan(&available); err != nil {
		return nil, err
	}
	if available+len(packages) > 50 {
		return nil, ErrStorageQuota
	}
	createdAt := time.Now().UTC()
	result := make([]domain.DeviceKeyPackage, 0, len(packages))
	for _, input := range packages {
		id, err := domain.NewID("kp")
		if err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO device_key_packages(id, device_id, key_package, ciphersuite, created_at, expires_at) VALUES(?, ?, ?, ?, ?, ?)`, id, deviceID, input.KeyPackage, input.Ciphersuite, formatTime(createdAt), formatTime(input.ExpiresAt)); err != nil {
			return nil, err
		}
		result = append(result, domain.DeviceKeyPackage{ID: id, DeviceID: deviceID, KeyPackage: input.KeyPackage, Ciphersuite: input.Ciphersuite, CreatedAt: createdAt, ExpiresAt: input.ExpiresAt})
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Store) ClaimConversationKeyPackages(ctx context.Context, conversationID, requesterAccountID, requesterDeviceID string) ([]domain.DeviceKeyPackage, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var member bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?)`, conversationID, requesterAccountID).Scan(&member); err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	rows, err := tx.QueryContext(ctx, `
		SELECT d.id, d.account_id
		FROM devices d
		JOIN memberships cm ON cm.account_id = d.account_id
		WHERE cm.conversation_id = ? AND d.revoked_at IS NULL AND d.id <> ?
		ORDER BY d.account_id, d.id`, conversationID, requesterDeviceID)
	if err != nil {
		return nil, err
	}
	type target struct{ deviceID, accountID string }
	var targets []target
	for rows.Next() {
		var item target
		if err := rows.Scan(&item.deviceID, &item.accountID); err != nil {
			rows.Close()
			return nil, err
		}
		targets = append(targets, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	claimedAt := time.Now().UTC()
	result := make([]domain.DeviceKeyPackage, 0, len(targets))
	for _, target := range targets {
		// A group is created with every device or not at all, so one device
		// over its limit refuses the whole claim (the transaction rolls back
		// what was claimed before it).
		allowed, err := s.keyPackageClaimAllowed(ctx, tx, target.deviceID, target.accountID, requesterAccountID, claimedAt)
		if err != nil {
			return nil, err
		}
		if !allowed {
			return nil, s.refuse(admission.KeyPackages, ErrKeyPackageClaimLimit)
		}
		var item domain.DeviceKeyPackage
		var createdAt, expiresAt string
		err = tx.QueryRowContext(ctx, `
			SELECT id, key_package, ciphersuite, created_at, expires_at
			FROM device_key_packages
			WHERE device_id = ? AND claimed_at IS NULL AND expires_at > ?
			ORDER BY created_at, id
			LIMIT 1`, target.deviceID, formatTime(claimedAt)).Scan(&item.ID, &item.KeyPackage, &item.Ciphersuite, &createdAt, &expiresAt)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrKeyPackageUnavailable
		}
		if err != nil {
			return nil, err
		}
		updated, err := tx.ExecContext(ctx, `UPDATE device_key_packages SET claimed_at = ?, claimed_by_device_id = ? WHERE id = ? AND claimed_at IS NULL`, formatTime(claimedAt), requesterDeviceID, item.ID)
		if err != nil {
			return nil, err
		}
		count, err := updated.RowsAffected()
		if err != nil || count != 1 {
			return nil, ErrKeyPackageUnavailable
		}
		item.DeviceID = target.deviceID
		item.AccountID = target.accountID
		item.CreatedAt = parseTime(createdAt)
		item.ExpiresAt = parseTime(expiresAt)
		result = append(result, item)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return result, nil
}
