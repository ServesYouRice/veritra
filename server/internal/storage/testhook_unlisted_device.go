//go:build veritra_testhooks

package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"private-messenger/server/internal/mlswire"
)

// InsertUnlistedDeviceForTest makes this server act as a malicious one for
// the live L1-5 run (docs/designs/L1-approved-device-list.md, "L1-5 Review
// and demo"): it inserts a device for accountID that no signed device list
// version names, with keyPackage as its one key package, and also writes
// the device into the server's own index of the account's head. That index
// row is the lie: it makes the honest-server gates (pending adds, key
// package claims) offer the device to every peer, so the run shows that
// the clients, not the server, refuse it. The signed statements are left
// untouched; nothing here can make a client accept the device.
//
// Compiled only with the veritra_testhooks tag, and reached only through
// the offline test command, which refuses anything but a development
// environment.
func (s *Store) InsertUnlistedDeviceForTest(ctx context.Context, accountID, deviceID string, keyPackage []byte) error {
	accountID = strings.TrimSpace(accountID)
	deviceID = strings.TrimSpace(deviceID)
	if accountID == "" || deviceID == "" {
		return ErrInvalidInput
	}
	signingKey, err := mlswire.LeafSignatureKey(keyPackage)
	if err != nil {
		return fmt.Errorf("key package: %w", err)
	}
	if len(signingKey) != 32 {
		return errors.New("key package leaf signature key is not 32 bytes")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var head sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(version) FROM device_list_versions WHERE account_id = ?`, accountID).Scan(&head); err != nil {
		return err
	}
	if !head.Valid {
		return errors.New("the account has no signed device list")
	}
	now := formatTime(time.Now().UTC())
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, created_at) VALUES(?, ?, ?, ?, ?, ?)`,
		deviceID, accountID, "unlisted test device", keyPackage, signingKey, now); err != nil {
		return err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, deviceID, keyPackage, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO device_list_devices(account_id, device_id, signing_key, added_version) VALUES(?, ?, ?, ?)`,
		accountID, deviceID, signingKey, head.Int64); err != nil {
		return err
	}
	return tx.Commit()
}
