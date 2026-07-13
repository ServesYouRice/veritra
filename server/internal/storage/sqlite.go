package storage

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

var (
	ErrAlreadySetup       = errors.New("instance already has an owner")
	ErrInviteInvalid      = errors.New("invite is invalid, expired, revoked, or fully used")
	ErrUnauthorized       = errors.New("unauthorized")
	ErrForbidden          = errors.New("forbidden")
	ErrNotFound           = errors.New("not found")
	ErrNotMember          = errors.New("account is not a conversation member")
	ErrInvalidInput       = errors.New("invalid input")
	ErrDeviceLinkInvalid  = errors.New("device link is invalid, expired, revoked, or already used")
	ErrDeviceLinkNotReady = errors.New("device link is not approved yet")

	// ErrDeviceLinkVerificationFailed is returned when the approver does not
	// supply the link's verification code, so a device cannot be approved
	// without the human confirming the out-of-band code shown on both devices.
	ErrDeviceLinkVerificationFailed = errors.New("device link verification code does not match")
)

type Store struct {
	db *dbRouter
}

type dbRouter struct {
	reader *sql.DB
	writer *sql.DB
}

func (db *dbRouter) ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
	return db.writer.ExecContext(ctx, query, args...)
}

func (db *dbRouter) QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
	return db.reader.QueryContext(ctx, query, args...)
}

func (db *dbRouter) QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row {
	return db.reader.QueryRowContext(ctx, query, args...)
}

func (db *dbRouter) BeginTx(ctx context.Context, opts *sql.TxOptions) (*sql.Tx, error) {
	return db.writer.BeginTx(ctx, opts)
}

func (db *dbRouter) PingContext(ctx context.Context) error {
	if err := db.writer.PingContext(ctx); err != nil {
		return err
	}
	return db.reader.PingContext(ctx)
}

func (db *dbRouter) Close() error {
	return errors.Join(db.reader.Close(), db.writer.Close())
}

func Open(ctx context.Context, cfg config.Config) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(cfg.DatabasePath), 0o700); err != nil {
		return nil, err
	}
	writer, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		return nil, err
	}
	writer.SetMaxOpenConns(1)
	writer.SetMaxIdleConns(1)
	if _, err := writer.ExecContext(ctx, "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;"); err != nil {
		_ = writer.Close()
		return nil, err
	}

	readerConns := runtime.NumCPU()
	if readerConns < 4 {
		readerConns = 4
	}
	if readerConns > 16 {
		readerConns = 16
	}
	reader, err := sql.Open("sqlite", cfg.DatabasePath)
	if err != nil {
		_ = writer.Close()
		return nil, err
	}
	reader.SetMaxOpenConns(readerConns)
	reader.SetMaxIdleConns(readerConns)
	if _, err := reader.ExecContext(ctx, "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;"); err != nil {
		_ = reader.Close()
		_ = writer.Close()
		return nil, err
	}

	// Query calls use their own pool. SQLite's WAL mode gives those reads
	// deferred transactions by default, while writes stay serialized through
	// the single writer connection.
	store := &Store{db: &dbRouter{reader: reader, writer: writer}}
	return store, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) Check(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

// BackupTo writes an atomic single-file copy of the database to dest using
// SQLite's VACUUM INTO. The destination must not already exist. This holds
// a read lock for the duration of the copy but does not block writers.
func (s *Store) BackupTo(ctx context.Context, dest string) error {
	if strings.TrimSpace(dest) == "" {
		return fmt.Errorf("backup destination required")
	}
	if _, err := os.Stat(dest); err == nil {
		return fmt.Errorf("backup destination already exists: %s", dest)
	}
	// VACUUM INTO does not accept parameter binding for the filename literal,
	// so quote it. Single-quotes are the SQL string delimiter; double them
	// inside the literal to escape per SQLite syntax. The path comes from a
	// trusted operator (CLI flag), not user input.
	escaped := strings.ReplaceAll(dest, "'", "''")
	_, err := s.db.reader.ExecContext(ctx, fmt.Sprintf("VACUUM INTO '%s'", escaped))
	return err
}

func (s *Store) Migrate(ctx context.Context, migrations fs.FS) error {
	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, checksum_sha256 TEXT NOT NULL, applied_at TEXT NOT NULL)`); err != nil {
		return err
	}
	checksumColumnAdded, err := s.ensureMigrationChecksumColumn(ctx)
	if err != nil {
		return err
	}
	entries, err := fs.ReadDir(migrations, ".")
	if err != nil {
		return err
	}
	var names []string
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		sqlBytes, err := fs.ReadFile(migrations, name)
		if err != nil {
			return err
		}
		checksum := migrationChecksum(sqlBytes)
		appliedChecksum, applied, err := s.appliedMigrationChecksum(ctx, name)
		if err != nil {
			return err
		}
		if applied {
			if appliedChecksum == "" {
				if !checksumColumnAdded {
					return fmt.Errorf("migration %s has no stored checksum", name)
				}
				if _, err := s.db.ExecContext(ctx, `UPDATE schema_migrations SET checksum_sha256 = ? WHERE version = ? AND (checksum_sha256 IS NULL OR checksum_sha256 = '')`, checksum, name); err != nil {
					return err
				}
				continue
			}
			if !strings.EqualFold(appliedChecksum, checksum) {
				return fmt.Errorf("migration %s checksum mismatch: applied %s, current %s", name, appliedChecksum, checksum)
			}
			continue
		}
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, string(sqlBytes)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("apply migration %s: %w", name, err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations(version, checksum_sha256, applied_at) VALUES(?, ?, ?)`, name, checksum, nowString()); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ensureMigrationChecksumColumn(ctx context.Context) (bool, error) {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(schema_migrations)`)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	hasChecksum := false
	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull int
		var defaultValue interface{}
		var pk int
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &pk); err != nil {
			return false, err
		}
		if name == "checksum_sha256" {
			hasChecksum = true
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	if hasChecksum {
		return false, nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE schema_migrations ADD COLUMN checksum_sha256 TEXT`)
	return err == nil, err
}

func (s *Store) appliedMigrationChecksum(ctx context.Context, version string) (string, bool, error) {
	var checksum sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT checksum_sha256 FROM schema_migrations WHERE version = ?`, version).Scan(&checksum)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", false, nil
		}
		return "", false, err
	}
	if !checksum.Valid {
		return "", true, nil
	}
	return checksum.String, true, nil
}

func migrationChecksum(sqlBytes []byte) string {
	sum := sha256.Sum256(sqlBytes)
	return hex.EncodeToString(sum[:])
}

func (s *Store) SetupRequired(ctx context.Context) (bool, error) {
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts`).Scan(&count); err != nil {
		return false, err
	}
	return count == 0, nil
}

type CreateOwnerInput struct {
	InstanceName  string
	Username      string
	Email         *string
	PasswordHash  string
	DeviceName    string
	KeyPackage    []byte
	SessionHash   string
	SessionExpiry time.Time
}

type AccountDevice struct {
	Account domain.Account `json:"account"`
	Device  domain.Device  `json:"device"`
}

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
	accountID, err := domain.NewID("acct")
	if err != nil {
		return AccountDevice{}, err
	}
	deviceID, err := domain.NewID("dev")
	if err != nil {
		return AccountDevice{}, err
	}
	createdAt := nowString()
	instanceName := strings.TrimSpace(input.InstanceName)
	if instanceName == "" {
		instanceName = "Private Messenger"
	}
	username := domain.NormalizeUsername(input.Username)
	if _, err := tx.ExecContext(ctx, `INSERT INTO instances(id, name, setup_complete, created_at, updated_at) VALUES(1, ?, 1, ?, ?)`, instanceName, createdAt, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO accounts(id, username, email, password_hash, role, status, created_at) VALUES(?, ?, ?, ?, 'owner', 'active', ?)`, accountID, username, nullableString(input.Email), input.PasswordHash, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES(?, ?, ?, ?, ?)`, deviceID, accountID, strings.TrimSpace(input.DeviceName), input.KeyPackage, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if input.SessionHash != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at) VALUES(?, ?, ?, ?, ?)`, input.SessionHash, accountID, deviceID, formatTime(input.SessionExpiry), createdAt); err != nil {
			return AccountDevice{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return AccountDevice{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return AccountDevice{
		Account: domain.Account{ID: accountID, Username: username, Email: input.Email, Role: domain.RoleOwner, Status: "active", CreatedAt: created},
		Device:  domain.Device{ID: deviceID, AccountID: accountID, Name: strings.TrimSpace(input.DeviceName), KeyPackage: input.KeyPackage, CreatedAt: created},
	}, nil
}

type RegisterInput struct {
	InviteCode    string
	Username      string
	Email         *string
	PasswordHash  string
	DeviceName    string
	KeyPackage    []byte
	SessionHash   string
	SessionExpiry time.Time
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
	accountID, err := domain.NewID("acct")
	if err != nil {
		return AccountDevice{}, err
	}
	deviceID, err := domain.NewID("dev")
	if err != nil {
		return AccountDevice{}, err
	}
	createdAt := nowString()
	username := domain.NormalizeUsername(input.Username)
	if _, err := tx.ExecContext(ctx, `INSERT INTO accounts(id, username, email, password_hash, role, status, created_at) VALUES(?, ?, ?, ?, 'member', 'active', ?)`, accountID, username, nullableString(input.Email), input.PasswordHash, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES(?, ?, ?, ?, ?)`, deviceID, accountID, strings.TrimSpace(input.DeviceName), input.KeyPackage, createdAt); err != nil {
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE invites SET uses = uses + 1 WHERE id = ?`, inviteID); err != nil {
		return AccountDevice{}, err
	}
	if input.SessionHash != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at) VALUES(?, ?, ?, ?, ?)`, input.SessionHash, accountID, deviceID, formatTime(input.SessionExpiry), createdAt); err != nil {
			return AccountDevice{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return AccountDevice{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return AccountDevice{
		Account: domain.Account{ID: accountID, Username: username, Email: input.Email, Role: domain.RoleMember, Status: "active", CreatedAt: created},
		Device:  domain.Device{ID: deviceID, AccountID: accountID, Name: strings.TrimSpace(input.DeviceName), KeyPackage: input.KeyPackage, CreatedAt: created},
	}, nil
}

type LoginRecord struct {
	AccountID    string
	Username     string
	PasswordHash string
	Role         string
	DeviceID     string
}

func (s *Store) LoginRecord(ctx context.Context, username, deviceID string) (LoginRecord, error) {
	username = domain.NormalizeUsername(username)
	deviceID = strings.TrimSpace(deviceID)
	record := LoginRecord{}
	if deviceID == "" {
		return LoginRecord{}, ErrUnauthorized
	}
	err := s.db.QueryRowContext(ctx, `
		SELECT a.id, a.username, a.password_hash, a.role, d.id
		FROM accounts a JOIN devices d ON d.account_id = a.id
		WHERE a.username = ? AND d.id = ? AND a.deleted_at IS NULL AND d.revoked_at IS NULL`, username, deviceID).
		Scan(&record.AccountID, &record.Username, &record.PasswordHash, &record.Role, &record.DeviceID)
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
	_, err := s.db.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at) VALUES(?, ?, ?, ?, ?)`, tokenHash, accountID, nullableEmptyString(deviceID), formatTime(expiresAt), nowString())
	return err
}

func (s *Store) PrincipalByTokenHash(ctx context.Context, tokenHash string) (domain.Principal, error) {
	principal := domain.Principal{}
	err := s.db.QueryRowContext(ctx, `
		SELECT a.id, COALESCE(s.device_id, ''), a.username, a.role
		FROM sessions s JOIN accounts a ON a.id = s.account_id
		LEFT JOIN devices d ON d.id = s.device_id
		WHERE s.token_hash = ?
		  AND s.expires_at > ?
		  AND a.deleted_at IS NULL
		  AND (s.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))`, tokenHash, nowString()).
		Scan(&principal.AccountID, &principal.DeviceID, &principal.Username, &principal.Role)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Principal{}, ErrUnauthorized
		}
		return domain.Principal{}, err
	}
	return principal, nil
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
	rows, err := s.db.QueryContext(ctx, `SELECT id, code, created_by, max_uses, uses, expires_at, created_at, revoked_at FROM invites WHERE created_by = ? ORDER BY created_at DESC`, createdBy)
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

// ListCommunities returns the communities the given account is a member of,
// newest first.
func (s *Store) ListCommunities(ctx context.Context, accountID string) ([]domain.Community, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT c.id, c.name, c.created_by, c.created_at
		FROM communities c
		JOIN memberships m ON m.community_id = c.id
		WHERE m.account_id = ?
		ORDER BY c.created_at DESC`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	communities := []domain.Community{}
	for rows.Next() {
		var community domain.Community
		var created string
		if err := rows.Scan(&community.ID, &community.Name, &community.CreatedBy, &created); err != nil {
			return nil, err
		}
		community.CreatedAt = parseTime(created)
		communities = append(communities, community)
	}
	return communities, rows.Err()
}

// ListChannels returns a community's channels; the caller must be a member
// of the community.
func (s *Store) ListChannels(ctx context.Context, communityID, accountID string) ([]domain.Channel, error) {
	if _, err := s.CommunityMemberRole(ctx, communityID, accountID); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, community_id, name, kind, created_at FROM channels WHERE community_id = ? ORDER BY created_at`, communityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	channels := []domain.Channel{}
	for rows.Next() {
		var channel domain.Channel
		var created string
		if err := rows.Scan(&channel.ID, &channel.CommunityID, &channel.Name, &channel.Kind, &created); err != nil {
			return nil, err
		}
		channel.CreatedAt = parseTime(created)
		channels = append(channels, channel)
	}
	return channels, rows.Err()
}

func (s *Store) ListDevices(ctx context.Context, accountID string) ([]domain.Device, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, account_id, name, key_package, signing_key, created_at, last_seen_at, revoked_at FROM devices WHERE account_id = ? ORDER BY created_at`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var devices []domain.Device
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func (s *Store) CreateDeviceLink(ctx context.Context, accountID, deviceID string, ttl time.Duration) (domain.DeviceLink, error) {
	if ttl <= 0 || ttl > 30*time.Minute {
		ttl = 10 * time.Minute
	}
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NULL`, deviceID, accountID).Scan(&count); err != nil {
		return domain.DeviceLink{}, err
	}
	if count == 0 {
		return domain.DeviceLink{}, ErrUnauthorized
	}
	id, err := domain.NewID("dlink")
	if err != nil {
		return domain.DeviceLink{}, err
	}
	code, err := domain.NewInviteCode()
	if err != nil {
		return domain.DeviceLink{}, err
	}
	verificationCode, err := domain.NewVerificationCode()
	if err != nil {
		return domain.DeviceLink{}, err
	}
	createdAt := time.Now().UTC()
	expiresAt := createdAt.Add(ttl)
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO device_links(id, code, account_id, created_by_device_id, state, verification_code, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		id, code, accountID, deviceID, domain.DeviceLinkPending, verificationCode, formatTime(createdAt), formatTime(expiresAt))
	if err != nil {
		return domain.DeviceLink{}, err
	}
	return domain.DeviceLink{
		ID:                id,
		Code:              code,
		AccountID:         accountID,
		CreatedByDeviceID: deviceID,
		State:             domain.DeviceLinkPending,
		VerificationCode:  verificationCode,
		CreatedAt:         createdAt,
		ExpiresAt:         expiresAt,
	}, nil
}

func (s *Store) ClaimDeviceLink(ctx context.Context, code, deviceName string, keyPackage, signingKey []byte, claimTokenHash string) (domain.DeviceLink, error) {
	code = strings.TrimSpace(code)
	deviceName = strings.TrimSpace(deviceName)
	if code == "" || deviceName == "" || len(keyPackage) == 0 || claimTokenHash == "" {
		return domain.DeviceLink{}, ErrDeviceLinkInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, err
	}
	defer tx.Rollback()
	var link domain.DeviceLink
	row := tx.QueryRowContext(ctx, `
		SELECT id, code, account_id, created_by_device_id, state, verification_code, claimed_device_name, approved_device_id, created_at, expires_at, claimed_at, approved_at, consumed_at, revoked_at
		FROM device_links
		WHERE code = ? AND state = ? AND revoked_at IS NULL AND expires_at > ?`,
		code, domain.DeviceLinkPending, nowString())
	if err := scanDeviceLink(row, &link); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, ErrDeviceLinkInvalid
		}
		return domain.DeviceLink{}, err
	}
	now := nowString()
	result, err := tx.ExecContext(ctx, `
		UPDATE device_links
		SET state = ?, claimed_device_name = ?, claimed_key_package = ?, claimed_signing_key = ?, claim_token_hash = ?, claimed_at = ?
		WHERE id = ? AND state = ?`,
		domain.DeviceLinkClaimed, deviceName, keyPackage, nullableBytes(signingKey), claimTokenHash, now, link.ID, domain.DeviceLinkPending)
	if err != nil {
		return domain.DeviceLink{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.DeviceLink{}, err
	}
	if rows == 0 {
		return domain.DeviceLink{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return domain.DeviceLink{}, err
	}
	claimedAt := parseTime(now)
	link.State = domain.DeviceLinkClaimed
	link.ClaimedDeviceName = &deviceName
	link.ClaimedAt = &claimedAt
	link.Code = ""
	return link, nil
}

func (s *Store) DeviceLinkForAccount(ctx context.Context, linkID, accountID string) (domain.DeviceLink, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT id, code, account_id, created_by_device_id, state, verification_code, claimed_device_name, approved_device_id, created_at, expires_at, claimed_at, approved_at, consumed_at, revoked_at
		FROM device_links
		WHERE id = ? AND account_id = ? AND revoked_at IS NULL`, linkID, accountID)
	var link domain.DeviceLink
	if err := scanDeviceLink(row, &link); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, ErrNotFound
		}
		return domain.DeviceLink{}, err
	}
	link.Code = ""
	return link, nil
}

func (s *Store) ApproveDeviceLink(ctx context.Context, linkID, accountID, verificationCode string) (domain.DeviceLink, domain.Device, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	defer tx.Rollback()
	var link domain.DeviceLink
	var deviceName string
	var keyPackage []byte
	var signingKey []byte
	row := tx.QueryRowContext(ctx, `
		SELECT id, code, account_id, created_by_device_id, state, verification_code, claimed_device_name, approved_device_id, created_at, expires_at, claimed_at, approved_at, consumed_at, revoked_at,
		       claimed_device_name, claimed_key_package, claimed_signing_key
		FROM device_links
		WHERE id = ? AND account_id = ? AND state = ? AND revoked_at IS NULL AND expires_at > ?`,
		linkID, accountID, domain.DeviceLinkClaimed, nowString())
	if err := scanDeviceLinkForApproval(row, &link, &deviceName, &keyPackage, &signingKey); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkInvalid
		}
		return domain.DeviceLink{}, domain.Device{}, err
	}
	// The approver must confirm the out-of-band verification code shown on both
	// devices. Without this, an authenticated user could blindly approve an
	// attacker-controlled claimed device. Constant-time compare avoids leaking
	// the code through timing.
	if subtle.ConstantTimeCompare([]byte(strings.TrimSpace(verificationCode)), []byte(link.VerificationCode)) != 1 {
		return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkVerificationFailed
	}
	if strings.TrimSpace(deviceName) == "" || len(keyPackage) == 0 {
		return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkInvalid
	}
	deviceID, err := domain.NewID("dev")
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	now := nowString()
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, created_at) VALUES(?, ?, ?, ?, ?, ?)`, deviceID, accountID, deviceName, keyPackage, nullableBytes(signingKey), now); err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, approved_device_id = ?, approved_at = ? WHERE id = ? AND state = ?`, domain.DeviceLinkApproved, deviceID, now, linkID, domain.DeviceLinkClaimed)
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	if rows == 0 {
		return domain.DeviceLink{}, domain.Device{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return domain.DeviceLink{}, domain.Device{}, err
	}
	approvedAt := parseTime(now)
	link.State = domain.DeviceLinkApproved
	link.Code = ""
	link.ApprovedDeviceID = &deviceID
	link.ApprovedAt = &approvedAt
	device := domain.Device{ID: deviceID, AccountID: accountID, Name: deviceName, KeyPackage: keyPackage, SigningKey: signingKey, CreatedAt: approvedAt}
	return link, device, nil
}

func (s *Store) ConsumeApprovedDeviceLink(ctx context.Context, linkID, claimTokenHash, sessionTokenHash string, sessionExpiresAt time.Time) (AccountDevice, error) {
	if strings.TrimSpace(linkID) == "" || claimTokenHash == "" || sessionTokenHash == "" {
		return AccountDevice{}, ErrDeviceLinkInvalid
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AccountDevice{}, err
	}
	defer tx.Rollback()
	var state string
	err = tx.QueryRowContext(ctx, `
		SELECT state
		FROM device_links
		WHERE id = ? AND claim_token_hash = ? AND revoked_at IS NULL AND expires_at > ?`,
		linkID, claimTokenHash, nowString()).Scan(&state)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return AccountDevice{}, ErrDeviceLinkInvalid
		}
		return AccountDevice{}, err
	}
	if state != domain.DeviceLinkApproved {
		if state == domain.DeviceLinkClaimed || state == domain.DeviceLinkPending {
			return AccountDevice{}, ErrDeviceLinkNotReady
		}
		return AccountDevice{}, ErrDeviceLinkInvalid
	}
	row := tx.QueryRowContext(ctx, `
		SELECT a.id, a.username, a.email, a.role, a.status, a.created_at, a.deleted_at,
		       d.id, d.account_id, d.name, d.key_package, d.signing_key, d.created_at, d.last_seen_at, d.revoked_at
		FROM device_links dl
		JOIN accounts a ON a.id = dl.account_id
		JOIN devices d ON d.id = dl.approved_device_id
		WHERE dl.id = ? AND dl.claim_token_hash = ? AND dl.state = ? AND a.deleted_at IS NULL AND d.revoked_at IS NULL`,
		linkID, claimTokenHash, domain.DeviceLinkApproved)
	linked, err := scanAccountDevice(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return AccountDevice{}, ErrDeviceLinkInvalid
		}
		return AccountDevice{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at) VALUES(?, ?, ?, ?, ?)`, sessionTokenHash, linked.Account.ID, linked.Device.ID, formatTime(sessionExpiresAt), nowString()); err != nil {
		return AccountDevice{}, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE device_links SET state = ?, consumed_at = ? WHERE id = ? AND state = ?`, domain.DeviceLinkConsumed, nowString(), linkID, domain.DeviceLinkApproved)
	if err != nil {
		return AccountDevice{}, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return AccountDevice{}, err
	}
	if rows == 0 {
		return AccountDevice{}, ErrDeviceLinkInvalid
	}
	if err := tx.Commit(); err != nil {
		return AccountDevice{}, err
	}
	return linked, nil
}

func (s *Store) CreateCommunity(ctx context.Context, name, createdBy string) (domain.Community, error) {
	id, err := domain.NewID("comm")
	if err != nil {
		return domain.Community{}, err
	}
	createdAt := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Community{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO communities(id, name, created_by, created_at) VALUES(?, ?, ?, ?)`, id, strings.TrimSpace(name), createdBy, createdAt); err != nil {
		return domain.Community{}, err
	}
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return domain.Community{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, community_id, role, created_at) VALUES(?, ?, ?, 'owner', ?)`, membershipID, createdBy, id, createdAt); err != nil {
		return domain.Community{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Community{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Community{ID: id, Name: strings.TrimSpace(name), CreatedBy: createdBy, CreatedAt: created}, nil
}

func (s *Store) CreateChannel(ctx context.Context, communityID, name, kind, createdBy string) (domain.Channel, error) {
	role, err := s.CommunityMemberRole(ctx, communityID, createdBy)
	if err != nil {
		return domain.Channel{}, err
	}
	if !domain.CanManageMembers(role) {
		return domain.Channel{}, ErrForbidden
	}
	if kind == "" {
		kind = "private"
	}
	if kind != "private" && kind != "announcement" {
		return domain.Channel{}, ErrInvalidInput
	}
	id, err := domain.NewID("chan")
	if err != nil {
		return domain.Channel{}, err
	}
	createdAt := nowString()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO channels(id, community_id, name, kind, created_at) VALUES(?, ?, ?, ?, ?)`, id, communityID, strings.TrimSpace(name), kind, createdAt); err != nil {
		return domain.Channel{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Channel{ID: id, CommunityID: communityID, Name: strings.TrimSpace(name), Kind: kind, CreatedAt: created}, nil
}

type CreateConversationInput struct {
	Kind             string
	Title            *string
	CommunityID      *string
	ChannelID        *string
	CreatedBy        string
	RetentionSeconds *int64
	MemberAccountIDs []string
}

func (s *Store) CreateConversation(ctx context.Context, input CreateConversationInput) (domain.Conversation, error) {
	id, err := domain.NewID("conv")
	if err != nil {
		return domain.Conversation{}, err
	}
	createdAt := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Conversation{}, err
	}
	defer tx.Rollback()
	// A community-channel conversation must point at a channel the creator may
	// actually use: the creator has to belong to the community and the channel
	// must belong to that same community. Validated inside the transaction so it
	// is authoritative and consistent with the insert below.
	if input.Kind == "community_channel" {
		if input.CommunityID == nil || input.ChannelID == nil {
			return domain.Conversation{}, ErrForbidden
		}
		var memberCount int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE account_id = ? AND community_id = ?`, input.CreatedBy, *input.CommunityID).Scan(&memberCount); err != nil {
			return domain.Conversation{}, err
		}
		if memberCount == 0 {
			return domain.Conversation{}, ErrForbidden
		}
		var channelCommunity string
		if err := tx.QueryRowContext(ctx, `SELECT community_id FROM channels WHERE id = ?`, *input.ChannelID).Scan(&channelCommunity); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return domain.Conversation{}, ErrNotFound
			}
			return domain.Conversation{}, err
		}
		if channelCommunity != *input.CommunityID {
			return domain.Conversation{}, ErrForbidden
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, id, input.Kind, nullableString(input.Title), nullableString(input.CommunityID), nullableString(input.ChannelID), input.CreatedBy, nullableInt64(input.RetentionSeconds), createdAt); err != nil {
		return domain.Conversation{}, err
	}
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return domain.Conversation{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'owner', ?)`, membershipID, input.CreatedBy, id, createdAt); err != nil {
		return domain.Conversation{}, err
	}
	// Initial members are added in the same transaction so a mid-loop failure
	// cannot leave a half-populated conversation (the whole create rolls back).
	seen := map[string]struct{}{input.CreatedBy: {}}
	for _, accountID := range input.MemberAccountIDs {
		accountID = strings.TrimSpace(accountID)
		if accountID == "" {
			continue
		}
		if _, dup := seen[accountID]; dup {
			continue
		}
		seen[accountID] = struct{}{}
		memberRowID, err := domain.NewID("mbr")
		if err != nil {
			return domain.Conversation{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO NOTHING`, memberRowID, accountID, id, domain.RoleMember, createdAt); err != nil {
			return domain.Conversation{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, err
	}
	created, _ := time.Parse(time.RFC3339Nano, createdAt)
	return domain.Conversation{ID: id, Kind: input.Kind, Title: input.Title, CommunityID: input.CommunityID, ChannelID: input.ChannelID, CreatedBy: input.CreatedBy, RetentionSeconds: input.RetentionSeconds, CreatedAt: created}, nil
}

func (s *Store) AddConversationMember(ctx context.Context, conversationID, accountID, role string) error {
	if role == "" {
		role = domain.RoleMember
	}
	id, err := domain.NewID("mbr")
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO UPDATE SET role = excluded.role`, id, accountID, conversationID, role, nowString())
	return err
}

func (s *Store) ListConversations(ctx context.Context, accountID string) ([]domain.Conversation, error) {
	// Order by most recent activity (last non-deleted, non-expired message,
	// falling back to creation) and compute the caller's unread count from
	// their read-receipt cursor. Timestamps are fixed-width UTC (see
	// nowString), so lexical comparison matches chronological order.
	now := nowString()
	rows, err := s.db.QueryContext(ctx, `
		SELECT c.id, c.kind, c.title, c.community_id, c.channel_id, c.created_by, c.retention_seconds, c.created_at,
		       lm.last_message_at,
		       COALESCE((
		           SELECT COUNT(*) FROM message_envelopes me
		           WHERE me.conversation_id = c.id
		             AND me.sender_account_id != ?
		             AND me.deleted_at IS NULL
		             AND (me.expires_at IS NULL OR me.expires_at > ?)
		             AND (rr.message_id IS NULL OR me.created_at > (
		                 SELECT created_at FROM message_envelopes WHERE id = rr.message_id
		             ))
		       ), 0) AS unread_count
		FROM conversations c
		JOIN memberships m ON m.conversation_id = c.id
		LEFT JOIN read_receipts rr ON rr.conversation_id = c.id AND rr.account_id = ?
		LEFT JOIN (
		    SELECT conversation_id, MAX(created_at) AS last_message_at
		    FROM message_envelopes
		    WHERE deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)
		    GROUP BY conversation_id
		) lm ON lm.conversation_id = c.id
		WHERE m.account_id = ?
		ORDER BY COALESCE(lm.last_message_at, c.created_at) DESC, c.created_at DESC`,
		accountID, now, accountID, now, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var conversations []domain.Conversation
	for rows.Next() {
		conversation, err := scanConversationWithActivity(rows)
		if err != nil {
			return nil, err
		}
		conversations = append(conversations, conversation)
	}
	return conversations, rows.Err()
}

func (s *Store) UpdateConversationRetention(ctx context.Context, conversationID, updatedBy string, retentionSeconds *int64) (domain.Conversation, error) {
	role, err := s.ConversationMemberRole(ctx, conversationID, updatedBy)
	if err != nil {
		return domain.Conversation{}, err
	}
	if !domain.CanManageMembers(role) {
		return domain.Conversation{}, ErrForbidden
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Conversation{}, err
	}
	defer tx.Rollback()
	now := nowString()
	if _, err := tx.ExecContext(ctx, `UPDATE conversations SET retention_seconds = ? WHERE id = ?`, nullableInt64(retentionSeconds), conversationID); err != nil {
		return domain.Conversation{}, err
	}
	if retentionSeconds == nil {
		if _, err := tx.ExecContext(ctx, `DELETE FROM disappearing_policies WHERE conversation_id = ?`, conversationID); err != nil {
			return domain.Conversation{}, err
		}
	} else {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO disappearing_policies(conversation_id, retention_seconds, updated_by, updated_at)
			VALUES(?, ?, ?, ?)
			ON CONFLICT(conversation_id) DO UPDATE SET retention_seconds = excluded.retention_seconds, updated_by = excluded.updated_by, updated_at = excluded.updated_at`,
			conversationID, *retentionSeconds, updatedBy, now); err != nil {
			return domain.Conversation{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, err
	}
	return s.ConversationByID(ctx, conversationID)
}

func (s *Store) ConversationByID(ctx context.Context, conversationID string) (domain.Conversation, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, conversationID)
	conversation, err := scanConversation(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Conversation{}, ErrNotFound
		}
		return domain.Conversation{}, err
	}
	return conversation, nil
}

func (s *Store) ListConversationMemberIDs(ctx context.Context, conversationID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT account_id FROM memberships WHERE conversation_id = ?`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) ConversationMemberRole(ctx context.Context, conversationID, accountID string) (string, error) {
	var role string
	err := s.db.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID).Scan(&role)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotMember
		}
		return "", err
	}
	return role, nil
}

func (s *Store) CommunityMemberRole(ctx context.Context, communityID, accountID string) (string, error) {
	var role string
	err := s.db.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, accountID).Scan(&role)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotMember
		}
		return "", err
	}
	return role, nil
}

func (s *Store) IsConversationMember(ctx context.Context, conversationID, accountID string) (bool, error) {
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID).Scan(&count); err != nil {
		return false, err
	}
	return count > 0, nil
}

func (s *Store) SaveMessageEnvelope(ctx context.Context, envelope domain.MessageEnvelope) (domain.MessageEnvelope, bool, error) {
	if err := s.pruneExpiredMessageByIdempotency(ctx, envelope.SenderDeviceID, envelope.IdempotencyKey, time.Now().UTC()); err != nil {
		return domain.MessageEnvelope{}, false, err
	}
	existing, err := s.messageByIdempotency(ctx, envelope.SenderDeviceID, envelope.IdempotencyKey)
	if err == nil {
		return existing, true, nil
	}
	if !errors.Is(err, ErrNotFound) {
		return domain.MessageEnvelope{}, false, err
	}
	member, err := s.IsConversationMember(ctx, envelope.ConversationID, envelope.SenderAccountID)
	if err != nil {
		return domain.MessageEnvelope{}, false, err
	}
	if !member {
		return domain.MessageEnvelope{}, false, ErrNotMember
	}
	if envelope.ID == "" {
		envelope.ID, err = domain.NewID("msg")
		if err != nil {
			return domain.MessageEnvelope{}, false, err
		}
	}
	if len(envelope.CryptoMetadata) == 0 {
		envelope.CryptoMetadata = json.RawMessage(`{}`)
	}
	if len(envelope.AttachmentRefs) == 0 {
		envelope.AttachmentRefs = json.RawMessage(`[]`)
	}
	envelope.CreatedAt = time.Now().UTC()
	retentionSeconds, err := s.conversationRetention(ctx, envelope.ConversationID)
	if err != nil {
		return domain.MessageEnvelope{}, false, err
	}
	if retentionSeconds != nil {
		retentionExpiresAt := envelope.CreatedAt.Add(time.Duration(*retentionSeconds) * time.Second)
		if envelope.ExpiresAt == nil || envelope.ExpiresAt.After(retentionExpiresAt) {
			envelope.ExpiresAt = &retentionExpiresAt
		}
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		envelope.ID, envelope.ConversationID, envelope.SenderAccountID, envelope.SenderDeviceID, envelope.IdempotencyKey, envelope.Ciphertext, envelope.CryptoProtocol, string(envelope.CryptoMetadata), string(envelope.AttachmentRefs), nullableString(envelope.ReplyToID), nullableString(envelope.ThreadRootID), formatTime(envelope.CreatedAt), nullableTime(envelope.ExpiresAt))
	if err != nil {
		return domain.MessageEnvelope{}, false, err
	}
	return envelope, false, nil
}

func (s *Store) messageByIdempotency(ctx context.Context, deviceID, key string) (domain.MessageEnvelope, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at FROM message_envelopes WHERE sender_device_id = ? AND idempotency_key = ? AND (expires_at IS NULL OR expires_at > ?)`, deviceID, key, nowString())
	msg, err := scanMessage(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.MessageEnvelope{}, ErrNotFound
		}
		return domain.MessageEnvelope{}, err
	}
	return msg, nil
}

func (s *Store) MessageByID(ctx context.Context, messageID string) (domain.MessageEnvelope, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at FROM message_envelopes WHERE id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, nowString())
	msg, err := scanMessage(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.MessageEnvelope{}, ErrNotFound
		}
		return domain.MessageEnvelope{}, err
	}
	return msg, nil
}

func (s *Store) UpdateMessageEnvelope(ctx context.Context, messageID, accountID string, ciphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, error) {
	if len(ciphertext) == 0 || strings.TrimSpace(cryptoProtocol) == "" {
		return domain.MessageEnvelope{}, ErrForbidden
	}
	if len(cryptoMetadata) == 0 {
		cryptoMetadata = json.RawMessage(`{}`)
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE message_envelopes
		SET ciphertext = ?, crypto_protocol = ?, crypto_metadata_json = ?, edited_at = ?
		WHERE id = ? AND sender_account_id = ? AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)`,
		ciphertext, cryptoProtocol, string(cryptoMetadata), nowString(), messageID, accountID, nowString())
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	return s.messageAfterOwnedMutation(ctx, messageID, result)
}

func (s *Store) DeleteMessageEnvelope(ctx context.Context, messageID, accountID string, markerCiphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, error) {
	if len(markerCiphertext) == 0 || strings.TrimSpace(cryptoProtocol) == "" {
		return domain.MessageEnvelope{}, ErrForbidden
	}
	if len(cryptoMetadata) == 0 {
		cryptoMetadata = json.RawMessage(`{"deleted":true}`)
	}
	now := nowString()
	result, err := s.db.ExecContext(ctx, `
		UPDATE message_envelopes
		SET ciphertext = ?, crypto_protocol = ?, crypto_metadata_json = ?, deleted_at = ?
		WHERE id = ? AND sender_account_id = ? AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)`,
		markerCiphertext, cryptoProtocol, string(cryptoMetadata), now, messageID, accountID, nowString())
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	return s.messageAfterOwnedMutation(ctx, messageID, result)
}

func (s *Store) messageAfterOwnedMutation(ctx context.Context, messageID string, result sql.Result) (domain.MessageEnvelope, error) {
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	if rows == 0 {
		if _, err := s.MessageByID(ctx, messageID); errors.Is(err, ErrNotFound) {
			return domain.MessageEnvelope{}, ErrNotFound
		} else if err != nil {
			return domain.MessageEnvelope{}, err
		}
		return domain.MessageEnvelope{}, ErrForbidden
	}
	return s.MessageByID(ctx, messageID)
}

// ListMessagesOptions controls pagination for ListMessages. Only one of
// BeforeID/AfterID may be set; both empty returns the most recent page.
type ListMessagesOptions struct {
	Limit    int
	BeforeID string // returns messages strictly older than this message id
	AfterID  string // returns messages strictly newer than this message id
}

func (s *Store) ListMessages(ctx context.Context, conversationID, accountID string, opts ListMessagesOptions) ([]domain.MessageEnvelope, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	limit := opts.Limit
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	if opts.BeforeID != "" && opts.AfterID != "" {
		return nil, fmt.Errorf("before_id and after_id are mutually exclusive")
	}
	const cols = `id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at`
	var (
		rows *sql.Rows
	)
	switch {
	case opts.BeforeID != "":
		cursorAt, err := s.messageCursor(ctx, conversationID, opts.BeforeID)
		if err != nil {
			return nil, err
		}
		rows, err = s.db.QueryContext(ctx, `SELECT `+cols+` FROM message_envelopes
			WHERE conversation_id = ? AND (expires_at IS NULL OR expires_at > ?) AND (created_at < ? OR (created_at = ? AND id < ?))
			ORDER BY created_at DESC, id DESC LIMIT ?`,
			conversationID, nowString(), cursorAt, cursorAt, opts.BeforeID, limit)
		if err != nil {
			return nil, err
		}
	case opts.AfterID != "":
		cursorAt, err := s.messageCursor(ctx, conversationID, opts.AfterID)
		if err != nil {
			return nil, err
		}
		rows, err = s.db.QueryContext(ctx, `SELECT `+cols+` FROM message_envelopes
			WHERE conversation_id = ? AND (expires_at IS NULL OR expires_at > ?) AND (created_at > ? OR (created_at = ? AND id > ?))
			ORDER BY created_at ASC, id ASC LIMIT ?`,
			conversationID, nowString(), cursorAt, cursorAt, opts.AfterID, limit)
		if err != nil {
			return nil, err
		}
	default:
		rows, err = s.db.QueryContext(ctx, `SELECT `+cols+` FROM message_envelopes
			WHERE conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)
			ORDER BY created_at DESC, id DESC LIMIT ?`, conversationID, nowString(), limit)
		if err != nil {
			return nil, err
		}
	}
	defer rows.Close()
	var messages []domain.MessageEnvelope
	for rows.Next() {
		msg, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		messages = append(messages, msg)
	}
	return messages, rows.Err()
}

// messageCursor returns the created_at of a message in a conversation, or
// ErrNotFound if the message does not exist or belongs to a different
// conversation. Used to validate before/after cursors.
func (s *Store) messageCursor(ctx context.Context, conversationID, messageID string) (string, error) {
	var createdAt string
	err := s.db.QueryRowContext(ctx, `SELECT created_at FROM message_envelopes WHERE id = ? AND conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, conversationID, nowString()).Scan(&createdAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	return createdAt, nil
}

func (s *Store) conversationRetention(ctx context.Context, conversationID string) (*int64, error) {
	var retention sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT retention_seconds FROM conversations WHERE id = ?`, conversationID).Scan(&retention); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if !retention.Valid {
		return nil, nil
	}
	return &retention.Int64, nil
}

func (s *Store) pruneExpiredMessageByIdempotency(ctx context.Context, deviceID, key string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM message_envelopes WHERE sender_device_id = ? AND idempotency_key = ? AND expires_at IS NOT NULL AND expires_at <= ?`, deviceID, key, formatTime(now.UTC()))
	return err
}

// PruneExpiredMessages deletes server-held encrypted envelopes whose
// disappearing-message expiry has passed.
func (s *Store) PruneExpiredMessages(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM message_envelopes WHERE expires_at IS NOT NULL AND expires_at <= ?`, formatTime(now.UTC()))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// PruneSyncEvents deletes sync events older than the cutoff. Returns the
// number of rows removed. Intended to be run periodically by a background
// sweeper so the table doesn't grow unbounded.
func (s *Store) PruneSyncEvents(ctx context.Context, olderThan time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM sync_events WHERE created_at < ?`, formatTime(olderThan.UTC()))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// PruneAuditEvents deletes audit events older than the cutoff.
func (s *Store) PruneAuditEvents(ctx context.Context, olderThan time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM audit_events WHERE created_at < ?`, formatTime(olderThan.UTC()))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// RecordAuditEvent appends a metadata-only audit row. Callers MUST NOT pass
// message content, ciphertext, or any field that would defeat the privacy
// promise that admins cannot read user data.
func (s *Store) RecordAuditEvent(ctx context.Context, actorAccountID *string, eventType string, metadata interface{}) error {
	payload := json.RawMessage(`{}`)
	if metadata != nil {
		b, err := json.Marshal(metadata)
		if err != nil {
			return err
		}
		payload = b
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO audit_events(actor_account_id, event_type, metadata_json, created_at) VALUES(?, ?, ?, ?)`, nullableString(actorAccountID), eventType, string(payload), nowString())
	return err
}

func (s *Store) SaveSyncEvent(ctx context.Context, eventType string, accountID *string, conversationID string, payload interface{}) (int64, error) {
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	result, err := s.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES(?, ?, ?, ?, ?)`, eventType, nullableString(accountID), nullableEmptyString(conversationID), string(payloadBytes), nowString())
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

func (s *Store) ListSyncEvents(ctx context.Context, accountID string, afterID int64, limit int) ([]domain.SyncEvent, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, event_type, account_id, conversation_id, payload_json, created_at
		FROM (
			SELECT id, event_type, account_id, conversation_id, payload_json, created_at
			FROM sync_events
			WHERE id > ? AND account_id = ?
			UNION ALL
			SELECT se.id, se.event_type, se.account_id, se.conversation_id, se.payload_json, se.created_at
			FROM sync_events se
			JOIN memberships m ON m.conversation_id = se.conversation_id
			WHERE se.id > ? AND se.account_id IS NULL AND m.account_id = ?
		) visible_events
		ORDER BY id ASC
		LIMIT ?`, afterID, accountID, afterID, accountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []domain.SyncEvent
	for rows.Next() {
		event, err := scanSyncEvent(rows)
		if err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

func (s *Store) SearchMetadata(ctx context.Context, accountID, query string, limit, offset int) ([]domain.MetadataSearchResult, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return []domain.MetadataSearchResult{}, nil
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	exact := query
	prefixPattern := escapeLike(query) + "%"
	rows, err := s.db.QueryContext(ctx, `
		SELECT type, id, label
		FROM (
			-- Accounts are matched on the exact (case-insensitive) username only.
			-- Prefix/contains matching here would let any authenticated user walk
			-- the substring space and enumerate the entire user directory, which
			-- is a metadata leak for a private messenger. Communities/channels
			-- below stay prefix/contains because they are scoped to the caller's
			-- memberships. Prefix-only matching also keeps this endpoint on
			-- ordinary indexes instead of leading-wildcard scans.
			SELECT 'account' AS type, id, username AS label, 0 AS rank
			FROM accounts
			WHERE deleted_at IS NULL AND username = ? COLLATE NOCASE
			UNION ALL
			SELECT 'community' AS type, c.id, c.name AS label,
				CASE
					WHEN c.name = ? COLLATE NOCASE THEN 0
					ELSE 1
				END AS rank
			FROM communities c
			JOIN memberships m ON m.community_id = c.id
			WHERE m.account_id = ? AND c.name LIKE ? ESCAPE '\'
			UNION ALL
			SELECT 'channel' AS type, ch.id, ch.name AS label,
				CASE
					WHEN ch.name = ? COLLATE NOCASE THEN 0
					ELSE 1
				END AS rank
			FROM channels ch
			JOIN memberships m ON m.community_id = ch.community_id
			WHERE m.account_id = ? AND ch.name LIKE ? ESCAPE '\'
		)
		ORDER BY rank, label COLLATE NOCASE, type, id
		LIMIT ? OFFSET ?`,
		exact,
		exact, accountID, prefixPattern,
		exact, accountID, prefixPattern,
		limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results := make([]domain.MetadataSearchResult, 0, limit)
	for rows.Next() {
		var result domain.MetadataSearchResult
		if err := rows.Scan(&result.Type, &result.ID, &result.Label); err != nil {
			return nil, err
		}
		results = append(results, result)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return results, nil
}

func (s *Store) CreateAttachmentEnvelope(ctx context.Context, attachment domain.AttachmentEnvelope) (domain.AttachmentEnvelope, error) {
	if attachment.ConversationID != nil {
		member, err := s.IsConversationMember(ctx, *attachment.ConversationID, attachment.OwnerAccountID)
		if err != nil {
			return domain.AttachmentEnvelope{}, err
		}
		if !member {
			return domain.AttachmentEnvelope{}, ErrNotMember
		}
	}
	if attachment.ID == "" {
		id, err := domain.NewID("att")
		if err != nil {
			return domain.AttachmentEnvelope{}, err
		}
		attachment.ID = id
	}
	if len(attachment.CryptoMetadata) == 0 {
		attachment.CryptoMetadata = json.RawMessage(`{}`)
	}
	attachment.CreatedAt = time.Now().UTC()
	_, err := s.db.ExecContext(ctx, `INSERT INTO attachment_envelopes(id, owner_account_id, conversation_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, attachment.ID, attachment.OwnerAccountID, nullableString(attachment.ConversationID), attachment.StorageKey, attachment.CiphertextSHA256, attachment.SizeBytes, string(attachment.CryptoMetadata), formatTime(attachment.CreatedAt))
	return attachment, err
}

func (s *Store) CreateReaction(ctx context.Context, messageID, accountID string, reactionCiphertext []byte) error {
	msg, err := s.MessageByID(ctx, messageID)
	if err != nil {
		return err
	}
	member, err := s.IsConversationMember(ctx, msg.ConversationID, accountID)
	if err != nil {
		return err
	}
	if !member {
		return ErrNotMember
	}
	id, err := domain.NewID("react")
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO reactions(id, message_id, account_id, reaction_ciphertext, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(message_id, account_id) DO UPDATE SET reaction_ciphertext = excluded.reaction_ciphertext, created_at = excluded.created_at`, id, messageID, accountID, reactionCiphertext, nowString())
	return err
}

func (s *Store) MarkRead(ctx context.Context, conversationID, accountID, messageID string) error {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return err
	}
	if !member {
		return ErrNotMember
	}
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM message_envelopes WHERE id = ? AND conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, conversationID, nowString()).Scan(&count); err != nil {
		return err
	}
	if count == 0 {
		return ErrNotFound
	}
	// Guard against rewinding the read cursor: only advance to a message
	// whose created_at is at or after the currently-recorded one.
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO read_receipts(account_id, conversation_id, message_id, read_at)
		VALUES(?, ?, ?, ?)
		ON CONFLICT(account_id, conversation_id) DO UPDATE SET
			message_id = excluded.message_id,
			read_at = excluded.read_at
		WHERE excluded.message_id != read_receipts.message_id
		  AND (SELECT created_at FROM message_envelopes WHERE id = excluded.message_id) >=
		      (SELECT created_at FROM message_envelopes WHERE id = read_receipts.message_id)`,
		accountID, conversationID, messageID, nowString())
	return err
}

func (s *Store) CreatePushSubscription(ctx context.Context, accountID, deviceID, provider, endpoint string) error {
	id, err := domain.NewID("push")
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO push_subscriptions(id, account_id, device_id, provider, endpoint, created_at) VALUES(?, ?, ?, ?, ?, ?)`, id, accountID, nullableEmptyString(deviceID), provider, endpoint, nowString())
	return err
}

// DisablePushSubscription marks the subscription disabled if it belongs to
// the caller's account. Returns ErrNotFound when no matching active row exists.
func (s *Store) DisablePushSubscription(ctx context.Context, subscriptionID, accountID string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE push_subscriptions SET disabled_at = ? WHERE id = ? AND account_id = ? AND disabled_at IS NULL`, nowString(), subscriptionID, accountID)
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

func (s *Store) CreateCallSession(ctx context.Context, conversationID, accountID string, metadata json.RawMessage) (domain.CallSession, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return domain.CallSession{}, err
	}
	if !member {
		return domain.CallSession{}, ErrNotMember
	}
	id, err := domain.NewID("call")
	if err != nil {
		return domain.CallSession{}, err
	}
	if len(metadata) == 0 {
		metadata = json.RawMessage(`{}`)
	}
	createdAt := time.Now().UTC()
	_, err = s.db.ExecContext(ctx, `INSERT INTO call_sessions(id, conversation_id, created_by, state, metadata_json, created_at) VALUES(?, ?, ?, 'ringing', ?, ?)`, id, conversationID, accountID, string(metadata), formatTime(createdAt))
	if err != nil {
		return domain.CallSession{}, err
	}
	return domain.CallSession{ID: id, ConversationID: conversationID, CreatedBy: accountID, State: "ringing", Metadata: metadata, CreatedAt: createdAt}, nil
}

func (s *Store) CreateBackupBlob(ctx context.Context, accountID, deviceID, storageKey string, sizeBytes int64, keyDerivationMetadata json.RawMessage) error {
	if len(keyDerivationMetadata) == 0 {
		keyDerivationMetadata = json.RawMessage(`{}`)
	}
	id, err := domain.NewID("backup")
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, device_id, storage_key, size_bytes, key_derivation_metadata_json, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`, id, accountID, nullableEmptyString(deviceID), storageKey, sizeBytes, string(keyDerivationMetadata), nowString())
	return err
}

// ExportAccountOptions controls pagination of the message portion of an
// account export. Account, devices, and conversations are always returned in
// full; only messages are paginated.
type ExportAccountOptions struct {
	Limit    int
	BeforeID string
}

// ExportAccount returns the caller's account, devices, conversations, and a
// page of messages ordered newest-first. When opts.Limit is hit, the caller
// must paginate using opts.BeforeID with the id of the oldest message in the
// returned page. This replaces the prior silent 1000-message cap.
func (s *Store) ExportAccount(ctx context.Context, accountID string, opts ExportAccountOptions) (domain.AccountExport, error) {
	account, err := s.accountByID(ctx, accountID)
	if err != nil {
		return domain.AccountExport{}, err
	}
	devices, err := s.ListDevices(ctx, accountID)
	if err != nil {
		return domain.AccountExport{}, err
	}
	conversations, err := s.ListConversations(ctx, accountID)
	if err != nil {
		return domain.AccountExport{}, err
	}
	limit := opts.Limit
	if limit <= 0 || limit > 5000 {
		limit = 1000
	}
	messages, err := s.listVisibleMessagesForExport(ctx, accountID, opts.BeforeID, limit)
	if err != nil {
		return domain.AccountExport{}, err
	}
	return domain.AccountExport{Account: account, Devices: devices, Conversations: conversations, Messages: messages}, nil
}

func (s *Store) DeleteAccount(ctx context.Context, accountID string) error {
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ?`, accountID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE devices SET revoked_at = COALESCE(revoked_at, ?) WHERE account_id = ?`, now, accountID); err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, `UPDATE accounts SET status = 'deleted', deleted_at = COALESCE(deleted_at, ?) WHERE id = ?`, now, accountID)
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
	return tx.Commit()
}

func (s *Store) accountByID(ctx context.Context, accountID string) (domain.Account, error) {
	var account domain.Account
	var email, deleted sql.NullString
	var created string
	err := s.db.QueryRowContext(ctx, `SELECT id, username, email, role, status, created_at, deleted_at FROM accounts WHERE id = ?`, accountID).Scan(&account.ID, &account.Username, &email, &account.Role, &account.Status, &created, &deleted)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Account{}, ErrNotFound
		}
		return domain.Account{}, err
	}
	account.Email = stringPtr(email)
	account.CreatedAt = parseTime(created)
	account.DeletedAt = parseOptionalTime(deleted)
	return account, nil
}

func (s *Store) listVisibleMessagesForExport(ctx context.Context, accountID, beforeID string, limit int) ([]domain.MessageEnvelope, error) {
	const cols = `me.id, me.conversation_id, me.sender_account_id, me.sender_device_id, me.idempotency_key, me.ciphertext, me.crypto_protocol, me.crypto_metadata_json, me.attachment_refs_json, me.reply_to_id, me.thread_root_id, me.created_at, me.edited_at, me.deleted_at, me.expires_at`
	var rows *sql.Rows
	var err error
	if beforeID != "" {
		var cursorAt string
		err = s.db.QueryRowContext(ctx, `
			SELECT me.created_at FROM message_envelopes me
			JOIN memberships m ON m.conversation_id = me.conversation_id
			WHERE m.account_id = ? AND me.id = ? AND (me.expires_at IS NULL OR me.expires_at > ?)`, accountID, beforeID, nowString()).Scan(&cursorAt)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil, ErrNotFound
			}
			return nil, err
		}
		rows, err = s.db.QueryContext(ctx, `
			SELECT `+cols+`
			FROM message_envelopes me
			JOIN memberships m ON m.conversation_id = me.conversation_id
			WHERE m.account_id = ?
			  AND (me.expires_at IS NULL OR me.expires_at > ?)
			  AND (me.created_at < ? OR (me.created_at = ? AND me.id < ?))
			ORDER BY me.created_at DESC, me.id DESC
			LIMIT ?`, accountID, nowString(), cursorAt, cursorAt, beforeID, limit)
	} else {
		rows, err = s.db.QueryContext(ctx, `
			SELECT `+cols+`
			FROM message_envelopes me
			JOIN memberships m ON m.conversation_id = me.conversation_id
			WHERE m.account_id = ?
			  AND (me.expires_at IS NULL OR me.expires_at > ?)
			ORDER BY me.created_at DESC, me.id DESC
			LIMIT ?`, accountID, nowString(), limit)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var messages []domain.MessageEnvelope
	for rows.Next() {
		msg, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		messages = append(messages, msg)
	}
	return messages, rows.Err()
}

type scanner interface {
	Scan(dest ...interface{}) error
}

func scanAccountDevice(rows scanner) (AccountDevice, error) {
	var account domain.Account
	var email, accountDeleted, accountCreated sql.NullString
	var device domain.Device
	var signing []byte
	var deviceCreated string
	var lastSeen, revoked sql.NullString
	if err := rows.Scan(
		&account.ID, &account.Username, &email, &account.Role, &account.Status, &accountCreated, &accountDeleted,
		&device.ID, &device.AccountID, &device.Name, &device.KeyPackage, &signing, &deviceCreated, &lastSeen, &revoked,
	); err != nil {
		return AccountDevice{}, err
	}
	account.Email = stringPtr(email)
	account.CreatedAt = parseTime(accountCreated.String)
	account.DeletedAt = parseOptionalTime(accountDeleted)
	device.SigningKey = signing
	device.CreatedAt = parseTime(deviceCreated)
	device.LastSeenAt = parseOptionalTime(lastSeen)
	device.RevokedAt = parseOptionalTime(revoked)
	return AccountDevice{Account: account, Device: device}, nil
}

func scanDevice(rows scanner) (domain.Device, error) {
	var device domain.Device
	var signing []byte
	var lastSeen, revoked sql.NullString
	var created string
	if err := rows.Scan(&device.ID, &device.AccountID, &device.Name, &device.KeyPackage, &signing, &created, &lastSeen, &revoked); err != nil {
		return domain.Device{}, err
	}
	device.SigningKey = signing
	device.CreatedAt = parseTime(created)
	device.LastSeenAt = parseOptionalTime(lastSeen)
	device.RevokedAt = parseOptionalTime(revoked)
	return device, nil
}

func scanDeviceLink(rows scanner, link *domain.DeviceLink) error {
	var code, createdByDeviceID, claimedDeviceName, approvedDeviceID sql.NullString
	var created, expires, claimed, approved, consumed, revoked sql.NullString
	if err := rows.Scan(&link.ID, &code, &link.AccountID, &createdByDeviceID, &link.State, &link.VerificationCode, &claimedDeviceName, &approvedDeviceID, &created, &expires, &claimed, &approved, &consumed, &revoked); err != nil {
		return err
	}
	if code.Valid {
		link.Code = code.String
	}
	if createdByDeviceID.Valid {
		link.CreatedByDeviceID = createdByDeviceID.String
	}
	link.ClaimedDeviceName = stringPtr(claimedDeviceName)
	link.ApprovedDeviceID = stringPtr(approvedDeviceID)
	link.CreatedAt = parseTime(created.String)
	link.ExpiresAt = parseTime(expires.String)
	link.ClaimedAt = parseOptionalTime(claimed)
	link.ApprovedAt = parseOptionalTime(approved)
	link.ConsumedAt = parseOptionalTime(consumed)
	link.RevokedAt = parseOptionalTime(revoked)
	return nil
}

func scanDeviceLinkForApproval(rows scanner, link *domain.DeviceLink, deviceName *string, keyPackage *[]byte, signingKey *[]byte) error {
	var code, createdByDeviceID, claimedDeviceName, approvedDeviceID, claimedDeviceNameForDevice sql.NullString
	var created, expires, claimed, approved, consumed, revoked sql.NullString
	if err := rows.Scan(
		&link.ID, &code, &link.AccountID, &createdByDeviceID, &link.State, &link.VerificationCode, &claimedDeviceName, &approvedDeviceID, &created, &expires, &claimed, &approved, &consumed, &revoked,
		&claimedDeviceNameForDevice, keyPackage, signingKey,
	); err != nil {
		return err
	}
	if code.Valid {
		link.Code = code.String
	}
	if createdByDeviceID.Valid {
		link.CreatedByDeviceID = createdByDeviceID.String
	}
	link.ClaimedDeviceName = stringPtr(claimedDeviceName)
	link.ApprovedDeviceID = stringPtr(approvedDeviceID)
	link.CreatedAt = parseTime(created.String)
	link.ExpiresAt = parseTime(expires.String)
	link.ClaimedAt = parseOptionalTime(claimed)
	link.ApprovedAt = parseOptionalTime(approved)
	link.ConsumedAt = parseOptionalTime(consumed)
	link.RevokedAt = parseOptionalTime(revoked)
	if claimedDeviceNameForDevice.Valid {
		*deviceName = claimedDeviceNameForDevice.String
	}
	return nil
}

func scanConversation(rows scanner) (domain.Conversation, error) {
	var c domain.Conversation
	var title, communityID, channelID, created sql.NullString
	var retention sql.NullInt64
	if err := rows.Scan(&c.ID, &c.Kind, &title, &communityID, &channelID, &c.CreatedBy, &retention, &created); err != nil {
		return domain.Conversation{}, err
	}
	c.Title = stringPtr(title)
	c.CommunityID = stringPtr(communityID)
	c.ChannelID = stringPtr(channelID)
	if retention.Valid {
		c.RetentionSeconds = &retention.Int64
	}
	c.CreatedAt = parseTime(created.String)
	return c, nil
}

// scanConversationWithActivity reads the base conversation columns plus the
// last_message_at and unread_count derived by ListConversations.
func scanConversationWithActivity(rows scanner) (domain.Conversation, error) {
	var c domain.Conversation
	var title, communityID, channelID, created, lastMessage sql.NullString
	var retention sql.NullInt64
	var unread int64
	if err := rows.Scan(&c.ID, &c.Kind, &title, &communityID, &channelID, &c.CreatedBy, &retention, &created, &lastMessage, &unread); err != nil {
		return domain.Conversation{}, err
	}
	c.Title = stringPtr(title)
	c.CommunityID = stringPtr(communityID)
	c.ChannelID = stringPtr(channelID)
	if retention.Valid {
		c.RetentionSeconds = &retention.Int64
	}
	c.CreatedAt = parseTime(created.String)
	if lastMessage.Valid && lastMessage.String != "" {
		t := parseTime(lastMessage.String)
		c.LastMessageAt = &t
	}
	c.UnreadCount = unread
	return c, nil
}

func scanMessage(rows scanner) (domain.MessageEnvelope, error) {
	var msg domain.MessageEnvelope
	var cryptoMetadata, attachmentRefs string
	var replyTo, threadRoot, created, edited, deleted, expires sql.NullString
	if err := rows.Scan(&msg.ID, &msg.ConversationID, &msg.SenderAccountID, &msg.SenderDeviceID, &msg.IdempotencyKey, &msg.Ciphertext, &msg.CryptoProtocol, &cryptoMetadata, &attachmentRefs, &replyTo, &threadRoot, &created, &edited, &deleted, &expires); err != nil {
		return domain.MessageEnvelope{}, err
	}
	msg.CryptoMetadata = json.RawMessage(cryptoMetadata)
	msg.AttachmentRefs = json.RawMessage(attachmentRefs)
	msg.ReplyToID = stringPtr(replyTo)
	msg.ThreadRootID = stringPtr(threadRoot)
	msg.CreatedAt = parseTime(created.String)
	msg.EditedAt = parseOptionalTime(edited)
	msg.DeletedAt = parseOptionalTime(deleted)
	msg.ExpiresAt = parseOptionalTime(expires)
	return msg, nil
}

func scanSyncEvent(rows scanner) (domain.SyncEvent, error) {
	var event domain.SyncEvent
	var accountID, conversationID, created sql.NullString
	var payload string
	if err := rows.Scan(&event.ID, &event.Type, &accountID, &conversationID, &payload, &created); err != nil {
		return domain.SyncEvent{}, err
	}
	event.AccountID = stringPtr(accountID)
	if conversationID.Valid {
		event.ConversationID = conversationID.String
	}
	event.Payload = json.RawMessage(payload)
	event.CreatedAt = parseTime(created.String)
	return event, nil
}

func nullableString(value *string) sql.NullString {
	if value == nil || strings.TrimSpace(*value) == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: strings.TrimSpace(*value), Valid: true}
}

func nullableEmptyString(value string) sql.NullString {
	if strings.TrimSpace(value) == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: strings.TrimSpace(value), Valid: true}
}

func nullableTime(value *time.Time) sql.NullString {
	if value == nil {
		return sql.NullString{}
	}
	return sql.NullString{String: formatTime(value.UTC()), Valid: true}
}

func nullableInt64(value *int64) sql.NullInt64 {
	if value == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: *value, Valid: true}
}

func nullableBytes(value []byte) interface{} {
	if len(value) == 0 {
		return nil
	}
	return value
}

func stringPtr(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	v := value.String
	return &v
}

func parseOptionalTime(value sql.NullString) *time.Time {
	if !value.Valid {
		return nil
	}
	t := parseTime(value.String)
	return &t
}

func parseTime(value string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}
	}
	return t
}

func nowString() string {
	return formatTime(time.Now().UTC())
}

func formatTime(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000000Z")
}

func escapeLike(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `%`, `\%`)
	value = strings.ReplaceAll(value, `_`, `\_`)
	return value
}
