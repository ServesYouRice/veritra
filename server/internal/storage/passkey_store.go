package storage

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

// Passkey limits (docs/designs/B7-passkeys.md).
const (
	PasskeyCeremonyLifetime  = 3 * time.Minute
	MaxPasskeysPerAccount    = 10
	MaxOpenPasskeyCeremonies = 4
	MaxPasskeyNameLength     = 64
)

const (
	PasskeyCeremonyRegister = "register"
	PasskeyCeremonyLogin    = "login"

	passkeyAddedEventType   = "account.passkey_added"
	passkeyRemovedEventType = "account.passkey_removed"
)

var (
	// ErrPasskeyLimit: the account already holds MaxPasskeysPerAccount.
	ErrPasskeyLimit = errors.New("passkey limit reached")
	// ErrPasskeyDuplicate: the credential ID is already registered.
	ErrPasskeyDuplicate = errors.New("passkey credential already registered")
)

// PasskeyDevice is an active device and its active account, found by device
// ID alone: a passkey sign-in takes no username.
type PasskeyDevice struct {
	AccountID      string
	Username       string
	Role           string
	DeviceID       string
	DeviceAuthHash string
}

// PasskeyCredential is one stored passkey. The AAGUID is not stored.
type PasskeyCredential struct {
	ID             string
	CredentialID   []byte
	PublicKey      []byte
	Algorithm      int64
	SignCount      uint32
	BackupEligible bool
	BackupState    bool
	Transports     string
	Name           string
	CreatedAt      time.Time
	LastUsedAt     *time.Time
}

// PasskeyCeremony is one open registration or sign-in ceremony.
type PasskeyCeremony struct {
	ID          string
	Kind        string
	AccountID   string
	DeviceID    string
	SessionData []byte
	ExpiresAt   time.Time
}

// PasskeyDeviceByID returns the active device and account for deviceID, or
// ErrUnauthorized (unknown, revoked, suspended and deleted look the same).
func (s *Store) PasskeyDeviceByID(ctx context.Context, deviceID string) (PasskeyDevice, error) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return PasskeyDevice{}, ErrUnauthorized
	}
	var d PasskeyDevice
	err := s.db.QueryRowContext(ctx, `
		SELECT a.id, a.username, a.role, d.id, COALESCE(d.auth_secret_hash, '')
		FROM devices d JOIN accounts a ON a.id = d.account_id
		WHERE d.id = ? AND a.status = 'active' AND a.deleted_at IS NULL AND d.revoked_at IS NULL`, deviceID).
		Scan(&d.AccountID, &d.Username, &d.Role, &d.DeviceID, &d.DeviceAuthHash)
	if errors.Is(err, sql.ErrNoRows) {
		return PasskeyDevice{}, ErrUnauthorized
	}
	return d, err
}

// PasskeyAccount returns the account's username, for registration options.
func (s *Store) PasskeyAccountUsername(ctx context.Context, accountID string) (string, error) {
	var username string
	err := s.db.QueryRowContext(ctx, `SELECT username FROM accounts WHERE id = ? AND status = 'active' AND deleted_at IS NULL`, accountID).Scan(&username)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrUnauthorized
	}
	return username, err
}

// PasskeyUserHandle returns the account's 32-byte WebAuthn user handle. With
// create set it makes one at the first registration; otherwise it returns
// ErrNotFound when there is none. The handle is random, never the account ID.
func (s *Store) PasskeyUserHandle(ctx context.Context, accountID string, create bool) ([]byte, error) {
	read := func() ([]byte, error) {
		var handle []byte
		err := s.db.QueryRowContext(ctx, `SELECT user_handle FROM passkey_user_handles WHERE account_id = ?`, accountID).Scan(&handle)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return handle, err
	}
	handle, err := read()
	if err == nil || !errors.Is(err, ErrNotFound) || !create {
		return handle, err
	}
	fresh := make([]byte, 32)
	if _, err := rand.Read(fresh); err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO passkey_user_handles(account_id, user_handle, created_at) VALUES(?, ?, ?)`, accountID, fresh, nowString()); err != nil {
		return nil, err
	}
	return read()
}

// ListPasskeys returns the account's passkeys, oldest first.
func (s *Store) ListPasskeys(ctx context.Context, accountID string) ([]PasskeyCredential, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, credential_id, public_key, algorithm, sign_count, backup_eligible, backup_state, transports, name, created_at, last_used_at
		FROM passkey_credentials WHERE account_id = ? ORDER BY created_at, id`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PasskeyCredential
	for rows.Next() {
		var c PasskeyCredential
		var signCount int64
		var eligible, state int
		var created string
		var used sql.NullString
		if err := rows.Scan(&c.ID, &c.CredentialID, &c.PublicKey, &c.Algorithm, &signCount, &eligible, &state, &c.Transports, &c.Name, &created, &used); err != nil {
			return nil, err
		}
		c.SignCount, c.BackupEligible, c.BackupState = uint32(signCount), eligible != 0, state != 0
		c.CreatedAt = parseTime(created)
		if used.Valid {
			t := parseTime(used.String)
			c.LastUsedAt = &t
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// CreatePasskeyCeremony stores a ceremony that expires after
// PasskeyCeremonyLifetime. A device holds at most MaxOpenPasskeyCeremonies:
// a new one evicts the oldest. The returned ID is 32 random bytes, base64url.
func (s *Store) CreatePasskeyCeremony(ctx context.Context, kind, accountID, deviceID string, sessionData []byte) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	id := base64.RawURLEncoding.EncodeToString(raw)
	now := time.Now().UTC()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM passkey_ceremonies WHERE expires_at <= ? AND device_id = ?`, formatTime(now), deviceID); err != nil {
		return "", err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM passkey_ceremonies WHERE id IN (
		SELECT id FROM passkey_ceremonies WHERE device_id = ? ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)`, deviceID, MaxOpenPasskeyCeremonies-1); err != nil {
		return "", err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO passkey_ceremonies(id, kind, account_id, device_id, session_data, created_at, expires_at) VALUES(?, ?, ?, ?, ?, ?, ?)`,
		id, kind, accountID, deviceID, sessionData, formatTime(now), formatTime(now.Add(PasskeyCeremonyLifetime))); err != nil {
		return "", err
	}
	return id, tx.Commit()
}

// PasskeyCeremonyByID returns an open (unexpired) ceremony of the given
// kind, or ErrUnauthorized.
func (s *Store) PasskeyCeremonyByID(ctx context.Context, id, kind string) (PasskeyCeremony, error) {
	var c PasskeyCeremony
	var expires string
	err := s.db.QueryRowContext(ctx, `SELECT id, kind, account_id, device_id, session_data, expires_at FROM passkey_ceremonies WHERE id = ? AND kind = ? AND expires_at > ?`,
		id, kind, nowString()).Scan(&c.ID, &c.Kind, &c.AccountID, &c.DeviceID, &c.SessionData, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return PasskeyCeremony{}, ErrUnauthorized
	}
	c.ExpiresAt = parseTime(expires)
	return c, err
}

// consumePasskeyCeremony deletes the ceremony and reports whether exactly one
// row went, so a ceremony is single-use even under concurrent finishes.
func consumePasskeyCeremony(ctx context.Context, tx *sql.Tx, id, kind, accountID, deviceID string) error {
	result, err := tx.ExecContext(ctx, `DELETE FROM passkey_ceremonies WHERE id = ? AND kind = ? AND account_id = ? AND device_id = ? AND expires_at > ?`,
		id, kind, accountID, deviceID, nowString())
	if err != nil {
		return err
	}
	if n, _ := result.RowsAffected(); n != 1 {
		return ErrUnauthorized
	}
	return nil
}

// AddPasskeyInput is a verified registration.
type AddPasskeyInput struct {
	CeremonyID string
	AccountID  string
	DeviceID   string
	Name       string
	Credential PasskeyCredential
}

// AddPasskey stores a verified passkey in one transaction that consumes the
// ceremony, enforces the limit and unique credential IDs, and writes the
// audit and sync events. They carry the row ID only.
func (s *Store) AddPasskey(ctx context.Context, in AddPasskeyInput) (string, error) {
	name := strings.TrimSpace(in.Name)
	if name == "" || len([]rune(name)) > MaxPasskeyNameLength || len(in.Credential.CredentialID) == 0 || len(in.Credential.PublicKey) == 0 {
		return "", ErrInvalidInput
	}
	rowID, err := domain.NewID("pk")
	if err != nil {
		return "", err
	}
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if err := consumePasskeyCeremony(ctx, tx, in.CeremonyID, PasskeyCeremonyRegister, in.AccountID, in.DeviceID); err != nil {
		return "", err
	}
	var count int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM passkey_credentials WHERE account_id = ?`, in.AccountID).Scan(&count); err != nil {
		return "", err
	}
	if count >= MaxPasskeysPerAccount {
		return "", ErrPasskeyLimit
	}
	c := in.Credential
	if _, err := tx.ExecContext(ctx, `INSERT INTO passkey_credentials(id, account_id, credential_id, public_key, algorithm, sign_count, backup_eligible, backup_state, transports, name, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rowID, in.AccountID, c.CredentialID, c.PublicKey, c.Algorithm, int64(c.SignCount), boolInt(c.BackupEligible), boolInt(c.BackupState), c.Transports, name, now); err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			return "", ErrPasskeyDuplicate
		}
		return "", err
	}
	payload := map[string]string{"passkey_id": rowID}
	if _, err := insertSyncEvent(ctx, tx, passkeyAddedEventType, &in.AccountID, "", payload, now); err != nil {
		return "", err
	}
	if err := insertAuditEvent(ctx, tx, &in.AccountID, "passkey.added", payload); err != nil {
		return "", err
	}
	return rowID, tx.Commit()
}

// RenamePasskey renames one of the account's passkeys.
func (s *Store) RenamePasskey(ctx context.Context, accountID, id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > MaxPasskeyNameLength {
		return ErrInvalidInput
	}
	result, err := s.db.ExecContext(ctx, `UPDATE passkey_credentials SET name = ? WHERE id = ? AND account_id = ?`, name, id, accountID)
	if err != nil {
		return err
	}
	if n, _ := result.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeletePasskey removes one of the account's passkeys and records it.
func (s *Store) DeletePasskey(ctx context.Context, accountID, id string) error {
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `DELETE FROM passkey_credentials WHERE id = ? AND account_id = ?`, id, accountID)
	if err != nil {
		return err
	}
	if n, _ := result.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	payload := map[string]string{"passkey_id": id}
	if _, err := insertSyncEvent(ctx, tx, passkeyRemovedEventType, &accountID, "", payload, now); err != nil {
		return err
	}
	if err := insertAuditEvent(ctx, tx, &accountID, "passkey.removed", payload); err != nil {
		return err
	}
	return tx.Commit()
}

// PasskeyLoginInput is a verified passkey sign-in, ready to commit.
type PasskeyLoginInput struct {
	CeremonyID string
	AccountID  string
	DeviceID   string
	// VerifiedDeviceAuthHash is the device secret hash that was checked.
	VerifiedDeviceAuthHash string
	PasskeyID              string
	// ReadSignCount is the count read before verification; NewSignCount the
	// one to store (the same when the authenticator reports no increase).
	ReadSignCount uint32
	NewSignCount  uint32
	BackupState   bool
	TokenHash     string
}

// FinishPasskeyLogin is the writer-transaction race fence: it consumes the
// ceremony (exactly one row), updates the passkey only while its count is
// still the one read, and inserts a session only while the account is
// active and the device is active with the verified secret. Any mismatch
// returns ErrUnauthorized and commits nothing. The session has no
// recent_auth_at: a passkey never counts as recent authentication.
func (s *Store) FinishPasskeyLogin(ctx context.Context, in PasskeyLoginInput) error {
	if in.TokenHash == "" || in.VerifiedDeviceAuthHash == "" {
		return ErrForbidden
	}
	now := nowString()
	idleExpiresAt, absoluteExpiresAt := s.sessionLifetime(time.Now().UTC(), time.Time{})
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := consumePasskeyCeremony(ctx, tx, in.CeremonyID, PasskeyCeremonyLogin, in.AccountID, in.DeviceID); err != nil {
		return err
	}
	result, err := tx.ExecContext(ctx, `UPDATE passkey_credentials SET sign_count = ?, backup_state = ?, last_used_at = ? WHERE id = ? AND account_id = ? AND sign_count = ?`,
		int64(in.NewSignCount), boolInt(in.BackupState), now, in.PasskeyID, in.AccountID, int64(in.ReadSignCount))
	if err != nil {
		return err
	}
	if n, _ := result.RowsAffected(); n != 1 {
		return ErrUnauthorized
	}
	result, err = tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at)
		SELECT ?, a.id, d.id, ?, ?, NULL, ?, ? FROM accounts a JOIN devices d ON d.account_id = a.id
		WHERE a.id = ? AND a.status = 'active' AND a.deleted_at IS NULL AND d.id = ? AND d.revoked_at IS NULL AND d.auth_secret_hash = ?`,
		in.TokenHash, idleExpiresAt, now, now, absoluteExpiresAt, in.AccountID, in.DeviceID, in.VerifiedDeviceAuthHash)
	if err != nil {
		return err
	}
	if n, _ := result.RowsAffected(); n != 1 {
		return ErrUnauthorized
	}
	return tx.Commit()
}

// deleteAccountPasskeysTx removes an account's passkeys, handle and open
// ceremonies (account deletion; K0 recovery completion).
func deleteAccountPasskeysTx(ctx context.Context, tx *sql.Tx, accountID string) error {
	for _, query := range []string{
		`DELETE FROM passkey_ceremonies WHERE account_id = ?`,
		`DELETE FROM passkey_credentials WHERE account_id = ?`,
		`DELETE FROM passkey_user_handles WHERE account_id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, query, accountID); err != nil {
			return err
		}
	}
	return nil
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
