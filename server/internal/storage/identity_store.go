package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/domain"
)

func (s *Store) CreateOwner(ctx context.Context, input CreateOwnerInput) (AccountDevice, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AccountDevice{}, err
	}
	defer tx.Rollback()
	var count int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts`).Scan(&count); err != nil {
		return AccountDevice{}, err
	}
	if count > 0 {
		return AccountDevice{}, ErrAlreadySetup
	}
	reservation, err := enrollmentReservationForTx(ctx, tx, input.EnrollmentReservationID, "owner")
	if err != nil {
		return AccountDevice{}, err
	}
	accountID := reservation.AccountID
	deviceID := reservation.DeviceID
	createdAt := nowString()
	instanceName := strings.TrimSpace(input.InstanceName)
	if instanceName == "" {
		instanceName = "Veritra"
	}
	username := domain.NormalizeUsername(input.Username)
	if _, err := tx.ExecContext(ctx, `INSERT INTO instances(id, name, setup_complete, created_at, updated_at) VALUES(1, ?, 1, ?, ?)`, instanceName, createdAt, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO accounts(id, username, email, password_hash, role, status, created_at) VALUES(?, ?, ?, ?, 'owner', 'active', ?)`, accountID, username, nullableString(input.Email), input.PasswordHash, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`, deviceID, accountID, strings.TrimSpace(input.DeviceName), input.KeyPackage, input.SigningKey, input.DeviceAuthHash, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, deviceID, input.KeyPackage, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if input.SessionHash != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at) VALUES(?, ?, ?, ?, ?, ?)`, input.SessionHash, accountID, deviceID, formatTime(input.SessionExpiry), createdAt, createdAt); err != nil {
			return AccountDevice{}, err
		}
	}
	if err := consumeEnrollmentReservation(ctx, tx, reservation.ID); err != nil {
		return AccountDevice{}, err
	}
	if err := tx.Commit(); err != nil {
		return AccountDevice{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return AccountDevice{
		Account: domain.Account{ID: accountID, Username: username, Email: input.Email, Role: domain.RoleOwner, Status: "active", CreatedAt: created},
		Device:  domain.Device{ID: deviceID, AccountID: accountID, Name: strings.TrimSpace(input.DeviceName), KeyPackage: input.KeyPackage, SigningKey: input.SigningKey, CreatedAt: created},
	}, nil
}

type RegisterInput struct {
	EnrollmentReservationID string
	InviteCode              string
	Username                string
	Email                   *string
	PasswordHash            string
	DeviceName              string
	KeyPackage              []byte
	SigningKey              []byte
	DeviceAuthHash          string
	SessionHash             string
	SessionExpiry           time.Time
}

func (s *Store) RegisterWithInvite(ctx context.Context, input RegisterInput) (AccountDevice, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AccountDevice{}, err
	}
	defer tx.Rollback()
	var inviteID string
	if err := tx.QueryRowContext(ctx, `SELECT id FROM invites WHERE code = ? AND revoked_at IS NULL AND uses < max_uses AND (expires_at IS NULL OR expires_at > ?)`, strings.TrimSpace(input.InviteCode), nowString()).Scan(&inviteID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return AccountDevice{}, ErrInviteInvalid
		}
		return AccountDevice{}, err
	}
	reservation, err := enrollmentReservationForTx(ctx, tx, input.EnrollmentReservationID, "register")
	if err != nil {
		return AccountDevice{}, err
	}
	if reservation.InviteID == nil || *reservation.InviteID != inviteID {
		return AccountDevice{}, ErrEnrollmentInvalid
	}
	accountID := reservation.AccountID
	deviceID := reservation.DeviceID
	createdAt := nowString()
	username := domain.NormalizeUsername(input.Username)
	if _, err := tx.ExecContext(ctx, `INSERT INTO accounts(id, username, email, password_hash, role, status, created_at) VALUES(?, ?, ?, ?, 'member', 'active', ?)`, accountID, username, nullableString(input.Email), input.PasswordHash, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`, deviceID, accountID, strings.TrimSpace(input.DeviceName), input.KeyPackage, input.SigningKey, input.DeviceAuthHash, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, deviceID, input.KeyPackage, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE invites SET uses = uses + 1 WHERE id = ?`, inviteID); err != nil {
		return AccountDevice{}, err
	}
	if input.SessionHash != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at) VALUES(?, ?, ?, ?, ?, ?)`, input.SessionHash, accountID, deviceID, formatTime(input.SessionExpiry), createdAt, createdAt); err != nil {
			return AccountDevice{}, err
		}
	}
	if err := consumeEnrollmentReservation(ctx, tx, reservation.ID); err != nil {
		return AccountDevice{}, err
	}
	if err := tx.Commit(); err != nil {
		return AccountDevice{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return AccountDevice{
		Account: domain.Account{ID: accountID, Username: username, Email: input.Email, Role: domain.RoleMember, Status: "active", CreatedAt: created},
		Device:  domain.Device{ID: deviceID, AccountID: accountID, Name: strings.TrimSpace(input.DeviceName), KeyPackage: input.KeyPackage, SigningKey: input.SigningKey, CreatedAt: created},
	}, nil
}

type LoginRecord struct {
	AccountID      string
	Username       string
	PasswordHash   string
	Role           string
	DeviceID       string
	DeviceAuthHash string
}

func (s *Store) LoginRecord(ctx context.Context, username, deviceID string) (LoginRecord, error) {
	username = domain.NormalizeUsername(username)
	deviceID = strings.TrimSpace(deviceID)
	record := LoginRecord{}
	if deviceID == "" {
		return LoginRecord{}, ErrUnauthorized
	}
	err := s.db.QueryRowContext(ctx, `
		SELECT a.id, a.username, a.password_hash, a.role, d.id, COALESCE(d.auth_secret_hash, '')
		FROM accounts a JOIN devices d ON d.account_id = a.id
		WHERE a.username = ? AND d.id = ? AND a.status = 'active' AND a.deleted_at IS NULL AND d.revoked_at IS NULL`, username, deviceID).
		Scan(&record.AccountID, &record.Username, &record.PasswordHash, &record.Role, &record.DeviceID, &record.DeviceAuthHash)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return LoginRecord{}, ErrUnauthorized
		}
		return LoginRecord{}, err
	}
	return record, nil
}

func (s *Store) CreateSession(ctx context.Context, tokenHash, accountID, deviceID string, expiresAt time.Time) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return ErrForbidden
	}
	now := nowString()
	_, err := s.db.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at) VALUES(?, ?, ?, ?, ?, ?)`, tokenHash, accountID, nullableEmptyString(deviceID), formatTime(expiresAt), now, now)
	return err
}

func (s *Store) PrincipalByTokenHash(ctx context.Context, tokenHash string) (domain.Principal, error) {
	principal := domain.Principal{}
	var expiresAt string
	var recentAuthAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT a.id, COALESCE(s.device_id, ''), a.username, a.role, s.expires_at, s.recent_auth_at
		FROM sessions s JOIN accounts a ON a.id = s.account_id
		LEFT JOIN devices d ON d.id = s.device_id
		WHERE s.token_hash = ?
		  AND s.expires_at > ?
		  AND a.status = 'active'
		  AND a.deleted_at IS NULL
		  AND (s.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))`, tokenHash, nowString()).
		Scan(&principal.AccountID, &principal.DeviceID, &principal.Username, &principal.Role, &expiresAt, &recentAuthAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Principal{}, ErrUnauthorized
		}
		return domain.Principal{}, err
	}
	principal.ExpiresAt = parseTime(expiresAt)
	principal.RecentAuthAt = parseOptionalTime(recentAuthAt)
	return principal, nil
}

// MarkDeviceSeen records coarse device activity for lost-device review. The
// five-minute write throttle avoids turning every authenticated request into a
// database write while keeping the value useful to the account owner.
func (s *Store) MarkDeviceSeen(ctx context.Context, deviceID string) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return nil
	}
	now := time.Now().UTC()
	_, err := s.db.ExecContext(ctx, `
		UPDATE devices
		SET last_seen_at = ?
		WHERE id = ?
		  AND revoked_at IS NULL
		  AND (last_seen_at IS NULL OR last_seen_at <= ?)`,
		formatTime(now), deviceID, formatTime(now.Add(-5*time.Minute)))
	return err
}

func (s *Store) ReauthenticationRecord(ctx context.Context, accountID, deviceID string) (string, string, error) {
	var passwordHash, deviceAuthHash string
	err := s.db.QueryRowContext(ctx, `SELECT a.password_hash, COALESCE(d.auth_secret_hash, '') FROM accounts a JOIN devices d ON d.account_id = a.id WHERE a.id = ? AND d.id = ? AND a.status = 'active' AND a.deleted_at IS NULL AND d.revoked_at IS NULL`, accountID, deviceID).Scan(&passwordHash, &deviceAuthHash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrUnauthorized
	}
	return passwordHash, deviceAuthHash, err
}

func (s *Store) MarkSessionRecentlyAuthenticated(ctx context.Context, tokenHash string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE sessions SET recent_auth_at = ? WHERE token_hash = ? AND expires_at > ?`, nowString(), tokenHash, nowString())
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return ErrUnauthorized
	}
	return nil
}

func (s *Store) ChangePassword(ctx context.Context, accountID, keepTokenHash, newPasswordHash string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE accounts SET password_hash = ? WHERE id = ? AND deleted_at IS NULL`, newPasswordHash, accountID)
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ? AND token_hash <> ?`, accountID, keepTokenHash); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE sessions SET recent_auth_at = ? WHERE token_hash = ?`, nowString(), keepTokenHash); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ResetOwnerPassword(ctx context.Context, username, newPasswordHash string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var accountID string
	if err := tx.QueryRowContext(ctx, `SELECT id FROM accounts WHERE username = ? AND role = 'owner' AND deleted_at IS NULL`, domain.NormalizeUsername(username)).Scan(&accountID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE accounts SET password_hash = ? WHERE id = ?`, newPasswordHash, accountID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ?`, accountID); err != nil {
		return err
	}
	metadata, _ := json.Marshal(map[string]string{"account_id": accountID, "method": "offline_owner_recovery"})
	if _, err := tx.ExecContext(ctx, `INSERT INTO audit_events(actor_account_id, event_type, metadata_json, created_at) VALUES(NULL, 'account.password_recovered', ?, ?)`, string(metadata), nowString()); err != nil {
		return err
	}
	return tx.Commit()
}

// DeleteSession removes a single session by its token hash (logout of the
// current device). It is a no-op if the session no longer exists.
func (s *Store) DeleteSession(ctx context.Context, tokenHash string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ?`, tokenHash)
	return err
}

// DeleteAccountSessionsExcept removes every session for the account except the
// one identified by keepTokenHash. Pass an empty keepTokenHash to remove all
// sessions (token_hash is never empty, so the comparison then matches all rows).
func (s *Store) DeleteAccountSessionsExcept(ctx context.Context, accountID, keepTokenHash string) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ? AND token_hash <> ?`, accountID, keepTokenHash)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// RevokeDevice marks one of an account's devices revoked and deletes its
// sessions atomically. It returns ErrNotFound when the device does not exist or
// belongs to a different account, so a caller can only revoke its own devices.
// PrincipalByTokenHash already rejects revoked devices on their next request.
func (s *Store) RevokeDevice(ctx context.Context, accountID, deviceID string) error {
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE devices SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ? AND account_id = ?`, now, deviceID, accountID)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE device_id = ?`, deviceID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) CreateInvite(ctx context.Context, createdBy string, maxUses int, expiresAt *time.Time) (domain.Invite, error) {
	if maxUses <= 0 {
		maxUses = 1
	}
	id, err := domain.NewID("inv")
	if err != nil {
		return domain.Invite{}, err
	}
	code, err := domain.NewInviteCode()
	if err != nil {
		return domain.Invite{}, err
	}
	createdAt := time.Now().UTC()
	_, err = s.db.ExecContext(ctx, `INSERT INTO invites(id, code, created_by, max_uses, expires_at, created_at) VALUES(?, ?, ?, ?, ?, ?)`, id, code, createdBy, maxUses, nullableTime(expiresAt), formatTime(createdAt))
	if err != nil {
		return domain.Invite{}, err
	}
	return domain.Invite{ID: id, Code: code, CreatedBy: createdBy, MaxUses: maxUses, Uses: 0, ExpiresAt: expiresAt, CreatedAt: createdAt}, nil
}

// ListInvites returns the invites created by the given account, newest
// first. Invites are intentionally not visible across accounts: the code is
// a bearer credential for registration.
func (s *Store) ListInvites(ctx context.Context, createdBy string) ([]domain.Invite, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, code, created_by, max_uses, uses, expires_at, created_at, revoked_at FROM invites WHERE created_by = ? AND revoked_at IS NULL AND uses < max_uses AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at DESC`, createdBy, nowString())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	invites := []domain.Invite{}
	for rows.Next() {
		var invite domain.Invite
		var expires, revoked sql.NullString
		var created string
		if err := rows.Scan(&invite.ID, &invite.Code, &invite.CreatedBy, &invite.MaxUses, &invite.Uses, &expires, &created, &revoked); err != nil {
			return nil, err
		}
		invite.ExpiresAt = parseOptionalTime(expires)
		invite.CreatedAt = parseTime(created)
		invite.RevokedAt = parseOptionalTime(revoked)
		invites = append(invites, invite)
	}
	return invites, rows.Err()
}

func (s *Store) RevokeInvite(ctx context.Context, createdBy, inviteID string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE invites SET revoked_at = ? WHERE id = ? AND created_by = ? AND revoked_at IS NULL`, nowString(), inviteID, createdBy)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrNotFound
	}
	return nil
}

// ListCommunities returns the communities the given account is a member of,
// newest first.
