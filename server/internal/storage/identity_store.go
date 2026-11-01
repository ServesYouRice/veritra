package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

const (
	// SessionIdleLifetime and SessionAbsoluteLifetime are the defaults; an
	// operator may change both (config.SessionIdleLifetime and
	// config.SessionAbsoluteLifetime). A session ends after the idle lifetime
	// without use, or the absolute lifetime after its last password and
	// device-secret authentication (login, or a rotating reauthentication).
	SessionIdleLifetime     = config.DefaultSessionIdleLifetime
	SessionAbsoluteLifetime = config.DefaultSessionAbsoluteLifetime

	// SessionRotationGrace is how long a rotated-out token keeps working, so
	// requests already in flight when the client switched tokens still
	// complete. The old token cannot carry recent authentication or extend
	// the session; only the newest token can.
	SessionRotationGrace = 2 * time.Minute

	// SessionTouchInterval bounds how often an authenticated request writes
	// sessions.last_used_at/expires_at. One minute caps the write rate at one
	// per session per minute (instead of one per request) while shortening the
	// effective idle lifetime by at most one minute, about 0.002% of
	// SessionIdleLifetime. Validity is still checked on every request.
	SessionTouchInterval = time.Minute
	// DeviceSeenInterval bounds devices.last_seen_at writes. The value is only
	// coarse lost-device review data, so five minutes is precise enough.
	DeviceSeenInterval = 5 * time.Minute
)

// SessionActivity is the stored activity of an authenticated session, read in
// the same query that validates it so callers can skip redundant writes.
type SessionActivity struct {
	LastUsedAt       time.Time
	DeviceLastSeenAt *time.Time
	// RotatedOut is true when the request used the session's previous token
	// inside SessionRotationGrace.
	RotatedOut bool
}

// SessionTouchDue reports whether TouchSession would write at now. A
// rotated-out token never extends the session.
func (a SessionActivity) SessionTouchDue(now time.Time) bool {
	return !a.RotatedOut && !a.LastUsedAt.After(now.Add(-SessionTouchInterval))
}

type sessionPolicy struct {
	idle     time.Duration
	absolute time.Duration
}

func newSessionPolicy(cfg config.Config) sessionPolicy {
	policy := sessionPolicy{idle: cfg.SessionIdleLifetime, absolute: cfg.SessionAbsoluteLifetime}
	if policy.idle <= 0 {
		policy.idle = SessionIdleLifetime
	}
	if policy.absolute <= 0 {
		policy.absolute = SessionAbsoluteLifetime
	}
	if policy.idle > policy.absolute {
		// config.Load rejects or resolves this; a direct caller is clamped.
		policy.idle = policy.absolute
	}
	return policy
}

// DeviceSeenDue reports whether MarkDeviceSeen would write at now.
func (a SessionActivity) DeviceSeenDue(now time.Time) bool {
	return a.DeviceLastSeenAt == nil || !a.DeviceLastSeenAt.After(now.Add(-DeviceSeenInterval))
}

// sessionLifetime returns the idle and absolute expiry for a session
// authenticated at authenticatedAt. newSessionPolicy keeps idle <= absolute,
// and a non-zero requestedExpiry can only shorten the idle expiry.
func (s *Store) sessionLifetime(authenticatedAt time.Time, requestedExpiry time.Time) (string, string) {
	idleExpiry := authenticatedAt.Add(s.sessions.idle)
	if !requestedExpiry.IsZero() && requestedExpiry.Before(idleExpiry) {
		idleExpiry = requestedExpiry
	}
	return formatTime(idleExpiry), formatTime(authenticatedAt.Add(s.sessions.absolute))
}

func (s *Store) idleCutoff(now time.Time) string {
	return formatTime(now.Add(-s.sessions.idle))
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
	reservation, err := enrollmentReservationForTx(ctx, tx, input.EnrollmentReservationID, "owner")
	if err != nil {
		return AccountDevice{}, err
	}
	accountID := reservation.AccountID
	deviceID := reservation.DeviceID
	createdAt := nowString()
	sessionExpiresAt, sessionAbsoluteExpiresAt := s.sessionLifetime(parseTime(createdAt), input.SessionExpiry)
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
		if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, input.SessionHash, accountID, deviceID, sessionExpiresAt, createdAt, createdAt, createdAt, sessionAbsoluteExpiresAt); err != nil {
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
	sessionExpiresAt, sessionAbsoluteExpiresAt := s.sessionLifetime(parseTime(createdAt), input.SessionExpiry)
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
		if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, input.SessionHash, accountID, deviceID, sessionExpiresAt, createdAt, createdAt, createdAt, sessionAbsoluteExpiresAt); err != nil {
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
	idleExpiresAt, absoluteExpiresAt := s.sessionLifetime(time.Now().UTC(), expiresAt)
	_, err := s.db.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, tokenHash, accountID, nullableEmptyString(deviceID), idleExpiresAt, now, now, now, absoluteExpiresAt)
	return err
}

// CreateLoginSession creates the session a password login earned, but only
// while the account's password hash is still the one the login verified.
// A password change or owner recovery that commits between the login's
// read and this insert deletes the account's sessions; without the check
// the late insert would survive it. It returns ErrUnauthorized, inserting
// nothing, when the hash moved or the account is no longer active.
func (s *Store) CreateLoginSession(ctx context.Context, tokenHash, accountID, deviceID, verifiedPasswordHash string) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" || verifiedPasswordHash == "" {
		return ErrForbidden
	}
	now := nowString()
	idleExpiresAt, absoluteExpiresAt := s.sessionLifetime(time.Now().UTC(), time.Time{})
	result, err := s.db.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at)
		SELECT ?, a.id, ?, ?, ?, ?, ?, ? FROM accounts a
		WHERE a.id = ? AND a.password_hash = ? AND a.status = 'active' AND a.deleted_at IS NULL`,
		tokenHash, deviceID, idleExpiresAt, now, now, now, absoluteExpiresAt, accountID, verifiedPasswordHash)
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return ErrUnauthorized
	}
	return nil
}

func (s *Store) PrincipalByTokenHash(ctx context.Context, tokenHash string) (domain.Principal, error) {
	principal, _, err := s.SessionPrincipal(ctx, tokenHash)
	return principal, err
}

// sessionValidity is the WHERE tail shared by every session lookup: expiry,
// absolute expiry, idle expiry, account status and device revocation. Its
// three placeholders take now, now and the idle cutoff.
const sessionValidity = `
		  AND s.expires_at > ?
		  AND s.absolute_expires_at > ?
		  AND s.last_used_at > ?
		  AND a.status = 'active'
		  AND a.deleted_at IS NULL
		  AND (s.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))`

const sessionPrincipalSelect = `
		SELECT a.id, COALESCE(s.device_id, ''), a.username, a.role, s.expires_at, s.recent_auth_at, s.last_used_at, d.last_seen_at, s.previous_expires_at
		FROM sessions s JOIN accounts a ON a.id = s.account_id
		LEFT JOIN devices d ON d.id = s.device_id`

// SessionPrincipal validates a session with a read-only query and returns its
// principal plus stored activity timestamps. Every expiry, idle, account and
// device-revocation rule is enforced here on each call. A rotated-out token
// is accepted only inside SessionRotationGrace, without recent
// authentication, and with ExpiresAt capped at the end of that grace.
func (s *Store) SessionPrincipal(ctx context.Context, tokenHash string) (domain.Principal, SessionActivity, error) {
	now := time.Now().UTC()
	nowValue := formatTime(now)
	principal, activity, err := scanSessionPrincipal(s.db.QueryRowContext(ctx,
		sessionPrincipalSelect+` WHERE s.token_hash = ?`+sessionValidity,
		tokenHash, nowValue, nowValue, s.idleCutoff(now)), false)
	if !errors.Is(err, ErrUnauthorized) {
		return principal, activity, err
	}
	// The current-token lookup above is the hot path; this second indexed
	// read runs only for unknown tokens and tokens inside the rotation grace.
	return scanSessionPrincipal(s.db.QueryRowContext(ctx,
		sessionPrincipalSelect+` WHERE s.previous_token_hash = ? AND s.previous_expires_at > ?`+sessionValidity,
		tokenHash, nowValue, nowValue, nowValue, s.idleCutoff(now)), true)
}

func scanSessionPrincipal(row *sql.Row, rotatedOut bool) (domain.Principal, SessionActivity, error) {
	principal := domain.Principal{}
	var expiresAt, lastUsedAt string
	var recentAuthAt, deviceLastSeenAt, previousExpiresAt sql.NullString
	err := row.Scan(&principal.AccountID, &principal.DeviceID, &principal.Username, &principal.Role, &expiresAt, &recentAuthAt, &lastUsedAt, &deviceLastSeenAt, &previousExpiresAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Principal{}, SessionActivity{}, ErrUnauthorized
		}
		return domain.Principal{}, SessionActivity{}, err
	}
	principal.ExpiresAt = parseTime(expiresAt)
	activity := SessionActivity{LastUsedAt: parseTime(lastUsedAt), RotatedOut: rotatedOut}
	if rotatedOut {
		if graceEnd := parseTime(previousExpiresAt.String); graceEnd.Before(principal.ExpiresAt) {
			principal.ExpiresAt = graceEnd
		}
	} else {
		principal.RecentAuthAt = parseOptionalTime(recentAuthAt)
	}
	if principal.DeviceID != "" {
		activity.DeviceLastSeenAt = parseOptionalTime(deviceLastSeenAt)
	}
	return principal, activity, nil
}

// MarkDeviceSeen records coarse device activity for lost-device review. The
// DeviceSeenInterval write throttle avoids turning every authenticated request into a
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
		formatTime(now), deviceID, formatTime(now.Add(-DeviceSeenInterval)))
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

// HasLegacyPasswordHashes reports whether any live account still has a
// bcrypt hash. Deleted accounts keep a non-hash marker and do not count.
func (s *Store) HasLegacyPasswordHashes(ctx context.Context) (bool, error) {
	var present bool
	err := s.db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM accounts WHERE deleted_at IS NULL AND substr(password_hash, 1, 4) IN ('$2a$', '$2b$', '$2y$'))`).Scan(&present)
	return present, err
}

// UpgradePasswordHash replaces an account's password hash with a rehash of
// the same password. A waiting recovery request that verified the old hash
// moves forward with it in the same transaction, so the rehash is not taken
// for a password change and does not void the recovery.
func (s *Store) UpgradePasswordHash(ctx context.Context, accountID, currentHash, updatedHash string) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE accounts SET password_hash = ? WHERE id = ? AND password_hash = ? AND deleted_at IS NULL`, updatedHash, accountID, currentHash)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows != 1 {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE account_recovery_requests SET verified_password_hash = ? WHERE account_id = ? AND state = 'waiting' AND verified_password_hash = ?`, updatedHash, accountID, currentHash); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

// TouchSession extends a valid session's idle expiry. The write is throttled to
// once per SessionTouchInterval: the conditional UPDATE only matches a valid
// session whose last_used_at is at least that old. When it matches nothing, a
// read-only check decides between "valid but recently touched" (nil, possibly
// by a concurrent request) and "expired, idle-expired or unknown"
// (ErrUnauthorized), so validation stays exact and there is no race.
func (s *Store) TouchSession(ctx context.Context, tokenHash string) error {
	now := time.Now().UTC()
	idleExpiry := formatTime(now.Add(s.sessions.idle))
	nowStringValue := formatTime(now)
	idleCutoff := s.idleCutoff(now)
	// The same write drops a rotated-out token whose grace has ended.
	result, err := s.db.ExecContext(ctx, `
		UPDATE sessions
		SET last_used_at = ?,
		    expires_at = CASE WHEN absolute_expires_at < ? THEN absolute_expires_at ELSE ? END,
		    previous_token_hash = CASE WHEN previous_expires_at > ? THEN previous_token_hash END,
		    previous_expires_at = CASE WHEN previous_expires_at > ? THEN previous_expires_at END
		WHERE token_hash = ?
		  AND expires_at > ?
		  AND absolute_expires_at > ?
		  AND last_used_at > ?
		  AND last_used_at <= ?`,
		nowStringValue, idleExpiry, idleExpiry, nowStringValue, nowStringValue, tokenHash, nowStringValue, nowStringValue, idleCutoff, formatTime(now.Add(-SessionTouchInterval)))
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows > 0 {
		return nil
	}
	var one int
	err = s.db.QueryRowContext(ctx, `
		SELECT 1 FROM sessions
		WHERE token_hash = ?
		  AND expires_at > ?
		  AND absolute_expires_at > ?
		  AND last_used_at > ?`,
		tokenHash, nowStringValue, nowStringValue, idleCutoff).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrUnauthorized
	}
	return err
}

// MarkSessionRecentlyAuthenticated records a reauthentication without
// rotating the token, for clients that do not ask for rotation. It does not
// renew the absolute lifetime; RotateSession does.
func (s *Store) MarkSessionRecentlyAuthenticated(ctx context.Context, tokenHash string) error {
	now := time.Now().UTC()
	result, err := s.db.ExecContext(ctx, `UPDATE sessions SET recent_auth_at = ?, last_used_at = ? WHERE token_hash = ? AND expires_at > ? AND absolute_expires_at > ? AND last_used_at > ?`, formatTime(now), formatTime(now), tokenHash, formatTime(now), formatTime(now), s.idleCutoff(now))
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return ErrUnauthorized
	}
	return nil
}

// RotateSession gives a session a new bearer token after its holder has
// re-authenticated with password and device secret. It is one statement, so
// concurrent rotations serialise on the writer:
//
//   - Presenting the current token makes newTokenHash current, keeps the
//     presented token for SessionRotationGrace, and drops any older token.
//   - Presenting the previous token inside its grace (a retry after a lost
//     response) replaces the current token instead. The grace is not
//     extended, so the token the client never received dies at once.
//
// Either way the session then has exactly one current token and at most one
// rotated-out token that expires within SessionRotationGrace. The rotation
// counts as a fresh authentication: recent-auth, idle and absolute lifetimes
// restart. Logout, password change, logout-all and device or account
// revocation remove the whole row or its rotated-out token, so revocation
// covers both tokens.
func (s *Store) RotateSession(ctx context.Context, presentedTokenHash, newTokenHash string) error {
	if presentedTokenHash == "" || newTokenHash == "" || presentedTokenHash == newTokenHash {
		return ErrUnauthorized
	}
	now := time.Now().UTC()
	nowValue := formatTime(now)
	idleExpiry, absoluteExpiry := s.sessionLifetime(now, time.Time{})
	result, err := s.db.ExecContext(ctx, `
		UPDATE sessions
		SET previous_token_hash = CASE WHEN token_hash = ?1 THEN token_hash ELSE previous_token_hash END,
		    previous_expires_at = CASE WHEN token_hash = ?1 THEN ?2 ELSE previous_expires_at END,
		    token_hash = ?3,
		    recent_auth_at = ?4,
		    last_used_at = ?4,
		    expires_at = ?5,
		    absolute_expires_at = ?6
		WHERE (token_hash = ?1 OR (previous_token_hash = ?1 AND previous_expires_at > ?4))
		  AND expires_at > ?4
		  AND absolute_expires_at > ?4
		  AND last_used_at > ?7`,
		presentedTokenHash, formatTime(now.Add(SessionRotationGrace)), newTokenHash, nowValue, idleExpiry, absoluteExpiry, s.idleCutoff(now))
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
	if _, err := tx.ExecContext(ctx, `UPDATE sessions SET recent_auth_at = ?, previous_token_hash = NULL, previous_expires_at = NULL WHERE token_hash = ?`, nowString(), keepTokenHash); err != nil {
		return err
	}
	if _, _, err := cancelWaitingRecoveryTx(ctx, tx, accountID, RecoveryCancelledPasswordChanged, nowString()); err != nil {
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
	if _, _, err := cancelWaitingRecoveryTx(ctx, tx, accountID, RecoveryCancelledPasswordReset, nowString()); err != nil {
		return err
	}
	metadata, _ := json.Marshal(map[string]string{"account_id": accountID, "method": "offline_owner_recovery"})
	if _, err := tx.ExecContext(ctx, `INSERT INTO audit_events(actor_account_id, event_type, metadata_json, created_at) VALUES(NULL, 'account.password_recovered', ?, ?)`, string(metadata), nowString()); err != nil {
		return err
	}
	return tx.Commit()
}

// DeleteSession removes a single session (logout of the current device) by
// its current token or by a rotated-out token still inside its grace; either
// way both tokens die. It is a no-op if the session no longer exists.
func (s *Store) DeleteSession(ctx context.Context, tokenHash string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash = ? OR (previous_token_hash = ? AND previous_expires_at > ?)`, tokenHash, tokenHash, nowString())
	return err
}

// DeleteAccountSessionsExcept removes every session for the account except the
// one identified by keepTokenHash, and drops the kept session's rotated-out
// token. Pass an empty keepTokenHash to remove all sessions (token_hash is
// never empty, so the comparison then matches all rows).
func (s *Store) DeleteAccountSessionsExcept(ctx context.Context, accountID, keepTokenHash string) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ? AND token_hash <> ?`, accountID, keepTokenHash)
	if err != nil {
		return 0, err
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE sessions SET previous_token_hash = NULL, previous_expires_at = NULL WHERE account_id = ? AND token_hash = ?`, accountID, keepTokenHash); err != nil {
		return 0, err
	}
	return deleted, tx.Commit()
}

// RevokeDevice marks one of an account's devices revoked and deletes its
// sessions atomically. It returns ErrNotFound when the device does not exist or
// belongs to a different account, so a caller can only revoke its own devices.
// PrincipalByTokenHash already rejects revoked devices on their next request.
func (s *Store) RevokeDevice(ctx context.Context, accountID, deviceID string) error {
	_, err := s.revokeDevice(ctx, accountID, deviceID, "")
	return err
}

func (s *Store) RevokeDeviceWithSyncEvent(ctx context.Context, accountID, deviceID string) (int64, error) {
	return s.revokeDevice(ctx, accountID, deviceID, "device.revoked")
}

func (s *Store) revokeDevice(ctx context.Context, accountID, deviceID, eventType string) (int64, error) {
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	eventID, err := revokeDeviceTx(ctx, tx, accountID, deviceID, eventType, now)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
}

// revokeDeviceTx runs every step of a device revocation in the caller's
// transaction: it marks the device revoked, deletes its sessions, retires
// its v3 links and, when eventType is set, records the event, queues its
// MLS revocations and releases the confirmations it owed. Recovery
// completion runs it for each old device.
func revokeDeviceTx(ctx context.Context, tx *sql.Tx, accountID, deviceID, eventType, now string) (int64, error) {
	result, err := tx.ExecContext(ctx, `UPDATE devices SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ? AND account_id = ?`, now, deviceID, accountID)
	if err != nil {
		return 0, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if rows == 0 {
		return 0, ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE device_id = ?`, deviceID); err != nil {
		return 0, err
	}
	if err := retireDeviceLinksV3ForDevice(ctx, tx, accountID, deviceID); err != nil {
		return 0, err
	}
	payload := map[string]string{"device_id": deviceID}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, &accountID, "", payload, now)
	if err != nil {
		return 0, err
	}
	if eventType != "" {
		if err := queueMLSRevocations(ctx, tx, accountID, deviceID, now); err != nil {
			return 0, err
		}
		if err := releaseMLSRevocationConfirmations(ctx, tx, deviceID, parseTime(now)); err != nil {
			return 0, err
		}
	}
	return eventID, nil
}

// queueMLSRevocations queues the removal of a revoked device from every MLS
// group it is in, in the caller's transaction: one mls_revocations row per
// group, the group devices that must confirm it, and an
// mls.revocation.pending event for the group. The device must already be
// marked revoked, and its account's membership must still be in place (groups
// without a recorded roster are found through it). A group that already has a
// revocation for the device keeps it and gets no second event.
func queueMLSRevocations(ctx context.Context, tx *sql.Tx, accountID, deviceID, now string) error {
	// Rostered groups (card I51) need a revocation only when the device is
	// in the group, and only group devices can coordinate or confirm it.
	// Without a roster only a legacy group (pre-I51: it has MLS messages, the
	// test CreateMLSCommitBundle uses) gets one. A conversation whose group
	// was never created has no leaf to remove, and a revoked device is never
	// added to a group created later. In a legacy group the stored
	// coordinator and the required confirmers are devices with evidence of a
	// leaf (mlsLegacyLeafEvidence), so a revocation never waits on a device
	// with none; the coordinator falls back to the lowest device only when
	// no device shows evidence, and mlsRevocationCoordinator re-checks it.
	rows, err := tx.QueryContext(ctx, `
		SELECT m.conversation_id,
		       COALESCE(MIN(CASE WHEN `+mlsLegacyLeafEvidence("m.conversation_id", "d.id", "d.created_at")+` THEN d.id END), MIN(d.id))
		FROM memberships m
		JOIN memberships participants ON participants.conversation_id = m.conversation_id
		JOIN devices d ON d.account_id = participants.account_id
		WHERE m.account_id = ? AND d.revoked_at IS NULL AND d.id <> ?
		  AND NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = m.conversation_id)
		  AND EXISTS (SELECT 1 FROM conversation_mls_messages lm WHERE lm.conversation_id = m.conversation_id)
		GROUP BY m.conversation_id
		UNION ALL
		SELECT r.conversation_id, MIN(r.device_id)
		FROM conversation_mls_devices target
		JOIN conversation_mls_devices r ON r.conversation_id = target.conversation_id
			AND r.removed_after_event_id IS NULL AND r.device_id <> target.device_id
		JOIN devices d ON d.id = r.device_id AND d.revoked_at IS NULL
		WHERE target.device_id = ? AND target.removed_after_event_id IS NULL
		GROUP BY r.conversation_id`, accountID, deviceID, deviceID)
	if err != nil {
		return err
	}
	type pendingRevocation struct{ conversationID, coordinatorDeviceID string }
	pending := make([]pendingRevocation, 0)
	for rows.Next() {
		var item pendingRevocation
		if err := rows.Scan(&item.conversationID, &item.coordinatorDeviceID); err != nil {
			rows.Close()
			return err
		}
		pending = append(pending, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, item := range pending {
		result, err := tx.ExecContext(ctx, `
			INSERT INTO mls_revocations(conversation_id, revoked_device_id, revoked_account_id,
				coordinator_device_id, state, requested_at)
			VALUES(?, ?, ?, ?, 'pending', ?)
			ON CONFLICT(conversation_id, revoked_device_id) DO NOTHING`,
			item.conversationID, deviceID, accountID, item.coordinatorDeviceID, now)
		if err != nil {
			return err
		}
		if queued, err := result.RowsAffected(); err != nil {
			return err
		} else if queued == 0 {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO mls_revocation_required_devices(
				conversation_id, revoked_device_id, device_id)
			SELECT ?, ?, d.id FROM memberships m
			JOIN devices d ON d.account_id = m.account_id
			WHERE m.conversation_id = ? AND d.revoked_at IS NULL AND d.id <> ?
			  AND ((NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = m.conversation_id)
			        AND `+mlsLegacyLeafEvidence("m.conversation_id", "d.id", "d.created_at")+`)
			       OR EXISTS (SELECT 1 FROM conversation_mls_devices r WHERE r.conversation_id = m.conversation_id
			                  AND r.device_id = d.id AND r.removed_after_event_id IS NULL))`,
			item.conversationID, deviceID, item.conversationID, deviceID); err != nil {
			return err
		}
		if _, err := insertSyncEvent(ctx, tx, "mls.revocation.pending", nil,
			item.conversationID, map[string]string{"device_id": deviceID, "account_id": accountID}, now); err != nil {
			return err
		}
	}
	return nil
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
