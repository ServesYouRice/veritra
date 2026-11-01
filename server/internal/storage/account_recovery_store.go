package storage

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

// K0 recovery enrollment, server side (docs/designs/K0-recovery-enrollment.md,
// package R2). The server stores only the recovery key's Ed25519
// verification key and rk_id; it never sees the recovery key itself.

var (
	// ErrRecoveryUnavailable means the instance has no recovery decoy key
	// yet (setup has not run), so recovery cannot start.
	ErrRecoveryUnavailable = errors.New("account recovery is unavailable")
	// ErrRecoveryCancelled means a recovery request was cancelled, expired,
	// or can no longer complete.
	ErrRecoveryCancelled = errors.New("account recovery request cancelled")
)

const (
	// RecoveryRequestUnclaimedLifetime is how long a ready request waits for
	// its claimant to complete it.
	RecoveryRequestUnclaimedLifetime = 3 * 24 * time.Hour

	RecoveryStateWaiting   = "waiting"
	RecoveryStateCompleted = "completed"

	RecoveryCancelledByOwner          = "owner"
	RecoveryCancelledReplaced         = "replaced"
	RecoveryCancelledPasswordChanged  = "password_changed"
	RecoveryCancelledPasswordReset    = "password_reset"
	RecoveryCancelledKeyChanged       = "recovery_key_changed"
	RecoveryCancelledCredentialsMoved = "credentials_changed"

	recoveryLeakSuspectedEventType = "account.password_leak_suspected"
	recoveryCancelledEventType     = "account.recovery.cancelled"
	recoveryPendingEventType       = "account.recovery.pending"
	recoveryRecoveredEventType     = "account.recovered"
	recoveryKeySetEventType        = "account.recovery_key.set"
	recoveryDecoyLabel             = "veritra-k0-recovery-decoy-v1"
	recoveryAttemptsDayLayout      = "2006-01-02"
	// recoveryAttemptsRetention keeps D79 rows for yesterday and today.
	recoveryAttemptsRetention = 2 * 24 * time.Hour
)

// recoveryAttemptsCutoffDay is the first day whose D79 rows are kept.
func recoveryAttemptsCutoffDay(now time.Time) string {
	return now.UTC().Add(-recoveryAttemptsRetention).Format(recoveryAttemptsDayLayout)
}

// recoveryDecoyKey returns the instance's decoy key, creating it on first
// use for an instance set up after migration 0045 (the migration backfills
// earlier ones). Before setup there is no instance row. It reads first, so
// the usual call never waits for the writer; only the first call after
// setup writes a key, from crypto/rand. Concurrent first callers each
// write only while the column is still NULL and then read it back, so all
// of them use the same key.
func (s *Store) recoveryDecoyKey(ctx context.Context) ([]byte, error) {
	key, err := s.readRecoveryDecoyKey(ctx)
	if err != nil || len(key) == 32 {
		return key, err
	}
	fresh := make([]byte, 32)
	if _, err := rand.Read(fresh); err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE instances SET recovery_decoy_key = ? WHERE id = 1 AND recovery_decoy_key IS NULL`, fresh); err != nil {
		return nil, err
	}
	key, err = s.readRecoveryDecoyKey(ctx)
	if err == nil && len(key) != 32 {
		return nil, ErrRecoveryUnavailable
	}
	return key, err
}

// readRecoveryDecoyKey returns the stored decoy key, nil when the instance
// has none yet, or ErrRecoveryUnavailable before setup.
func (s *Store) readRecoveryDecoyKey(ctx context.Context) ([]byte, error) {
	var key []byte
	err := s.db.QueryRowContext(ctx, `SELECT recovery_decoy_key FROM instances WHERE id = 1`).Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrRecoveryUnavailable
	}
	if err != nil {
		return nil, err
	}
	if key != nil && len(key) != 32 {
		return nil, ErrRecoveryUnavailable
	}
	return key, nil
}

// RecoveryDecoyAccountID is the stable decoy account id for a username that
// is not an active account: "acct_" + hex(HMAC-SHA256(key, username)[:16]),
// the same shape as domain.NewID("acct").
func RecoveryDecoyAccountID(key []byte, username string) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(recoveryDecoyLabel))
	mac.Write([]byte{0})
	mac.Write([]byte(domain.NormalizeUsername(username)))
	return "acct_" + hex.EncodeToString(mac.Sum(nil)[:16])
}

// ReserveRecoveryEnrollment reserves a recovery enrollment for username. An
// active account gets its real id; any other username (unknown, suspended,
// deleted) gets its stable decoy id, so the answer never says which.
func (s *Store) ReserveRecoveryEnrollment(ctx context.Context, username string) (EnrollmentReservation, error) {
	key, err := s.recoveryDecoyKey(ctx)
	if err != nil {
		return EnrollmentReservation{}, err
	}
	accountID := RecoveryDecoyAccountID(key, username)
	var realID string
	err = s.db.QueryRowContext(ctx, `SELECT id FROM accounts WHERE username = ? AND status = 'active' AND deleted_at IS NULL`, domain.NormalizeUsername(username)).Scan(&realID)
	switch {
	case err == nil:
		accountID = realID
	case !errors.Is(err, sql.ErrNoRows):
		return EnrollmentReservation{}, err
	}
	return s.createEnrollmentReservationFor(ctx, "recovery", nil, accountID)
}

// RecoveryReservation returns an unexpired, unconsumed recovery reservation.
func (s *Store) RecoveryReservation(ctx context.Context, id string) (EnrollmentReservation, error) {
	reservation, err := s.EnrollmentReservation(ctx, id)
	if err != nil {
		return EnrollmentReservation{}, err
	}
	if reservation.Kind != "recovery" {
		return EnrollmentReservation{}, ErrEnrollmentInvalid
	}
	return reservation, nil
}

// RecoveryClaimRecord is what a claim checks: the password hash and the
// recovery key's verification key (nil when none is set).
type RecoveryClaimRecord struct {
	AccountID     string
	PasswordHash  string
	AuthPublicKey []byte
}

// RecoveryClaimRecord loads an active account by id, as LoginRecord does by
// username. Any other id returns ErrUnauthorized.
func (s *Store) RecoveryClaimRecord(ctx context.Context, accountID string) (RecoveryClaimRecord, error) {
	record := RecoveryClaimRecord{AccountID: accountID}
	err := s.db.QueryRowContext(ctx, `
		SELECT a.password_hash, k.auth_public_key
		FROM accounts a LEFT JOIN account_recovery_keys k ON k.account_id = a.id
		WHERE a.id = ? AND a.status = 'active' AND a.deleted_at IS NULL`, accountID).
		Scan(&record.PasswordHash, &record.AuthPublicKey)
	if errors.Is(err, sql.ErrNoRows) {
		return RecoveryClaimRecord{}, ErrUnauthorized
	}
	if err != nil {
		return RecoveryClaimRecord{}, err
	}
	return record, nil
}

// RecoveryAttempt is the D79 counter after one claim.
type RecoveryAttempt struct {
	// Failures counts today's right-password-wrong-recovery-key claims for
	// the reservation's account (or decoy) id.
	Failures int
	// LeakEventID is the account.password_leak_suspected sync event written
	// by this call (the first time today the cap tripped on a real account),
	// or zero.
	LeakEventID int64
}

// RecordRecoveryAttempt writes the D79 row for (accountID, today) on every
// claim that reaches the credential checks, adding one when countFailure
// (right password, wrong recovery key). Writing every time keeps the work
// equal. The first time the count passes failureCap on a day, a real active
// account's devices get an account.password_leak_suspected sync event.
func (s *Store) RecordRecoveryAttempt(ctx context.Context, accountID string, countFailure bool, failureCap int, now time.Time) (RecoveryAttempt, error) {
	increment := 0
	if countFailure {
		increment = 1
	}
	day := now.UTC().Format(recoveryAttemptsDayLayout)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RecoveryAttempt{}, err
	}
	defer tx.Rollback()
	var attempt RecoveryAttempt
	var notified int
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO recovery_attempts(account_id, day, failures) VALUES(?, ?, ?)
		ON CONFLICT(account_id, day) DO UPDATE SET failures = failures + excluded.failures
		RETURNING failures, leak_notified`, accountID, day, increment).Scan(&attempt.Failures, &notified); err != nil {
		return RecoveryAttempt{}, err
	}
	if attempt.Failures > failureCap && notified == 0 {
		if _, err := tx.ExecContext(ctx, `UPDATE recovery_attempts SET leak_notified = 1 WHERE account_id = ? AND day = ?`, accountID, day); err != nil {
			return RecoveryAttempt{}, err
		}
		var active bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM accounts WHERE id = ? AND status = 'active' AND deleted_at IS NULL)`, accountID).Scan(&active); err != nil {
			return RecoveryAttempt{}, err
		}
		if active {
			eventID, err := insertSyncEvent(ctx, tx, recoveryLeakSuspectedEventType, &accountID, "", map[string]string{"day": day}, formatTime(now.UTC()))
			if err != nil {
				return RecoveryAttempt{}, err
			}
			attempt.LeakEventID = eventID
			if err := insertAuditEvent(ctx, tx, &accountID, "account.password_leak_suspected", map[string]string{"day": day}); err != nil {
				return RecoveryAttempt{}, err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return RecoveryAttempt{}, err
	}
	return attempt, nil
}

// RecoveryClaimInput is a claim whose credentials the handler verified.
type RecoveryClaimInput struct {
	ReservationID        string
	AccountID            string
	DeviceName           string
	KeyPackage           []byte
	SigningKey           []byte
	DeviceAuthHash       string
	ClaimTokenHash       string
	VerifiedPasswordHash string
	VerifiedAuthKey      []byte
	ActiveWindow         time.Duration
	Wait                 time.Duration
}

// RecoveryRequest is a stored recovery request.
type RecoveryRequest struct {
	ID         string    `json:"id"`
	AccountID  string    `json:"account_id"`
	DeviceID   string    `json:"device_id"`
	DeviceName string    `json:"device_name"`
	State      string    `json:"state"`
	CreatedAt  time.Time `json:"created_at"`
	ReadyAt    time.Time `json:"ready_at"`
	ExpiresAt  time.Time `json:"expires_at"`
}

// RecoveryClaimResult is what ClaimRecovery committed.
type RecoveryClaimResult struct {
	Request          RecoveryRequest
	PendingEventID   int64
	ReplacedRequest  string
	ReplacedEventID  int64
	ActiveDeviceSeen bool
}

// ClaimRecovery stores a verified claim in one transaction: it consumes the
// reservation (so completion does not depend on its 10-minute lifetime),
// replaces any waiting request of the account, and inserts the new one with
// the verified credentials. The wait applies when any device of the account
// is active: not revoked, with a live session, and seen within ActiveWindow.
// It returns ErrUnauthorized when the password hash or recovery key changed
// after the handler checked them.
func (s *Store) ClaimRecovery(ctx context.Context, input RecoveryClaimInput) (RecoveryClaimResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RecoveryClaimResult{}, err
	}
	defer tx.Rollback()
	reservation, err := enrollmentReservationForTx(ctx, tx, input.ReservationID, "recovery")
	if err != nil {
		return RecoveryClaimResult{}, err
	}
	if reservation.AccountID != input.AccountID {
		return RecoveryClaimResult{}, ErrEnrollmentInvalid
	}
	var current bool
	if err := tx.QueryRowContext(ctx, `
		SELECT EXISTS(SELECT 1 FROM accounts a JOIN account_recovery_keys k ON k.account_id = a.id
		WHERE a.id = ? AND a.status = 'active' AND a.deleted_at IS NULL
		  AND a.password_hash = ? AND k.auth_public_key = ?)`,
		input.AccountID, input.VerifiedPasswordHash, input.VerifiedAuthKey).Scan(&current); err != nil {
		return RecoveryClaimResult{}, err
	}
	if !current {
		return RecoveryClaimResult{}, ErrUnauthorized
	}
	if err := consumeEnrollmentReservation(ctx, tx, reservation.ID); err != nil {
		return RecoveryClaimResult{}, err
	}
	now := time.Now().UTC()
	nowText := formatTime(now)
	var active bool
	if err := tx.QueryRowContext(ctx, `
		SELECT EXISTS(SELECT 1 FROM devices d
		WHERE d.account_id = ? AND d.revoked_at IS NULL
		  AND COALESCE(d.last_seen_at, d.created_at) > ?
		  AND EXISTS(SELECT 1 FROM sessions s WHERE s.device_id = d.id
		    AND s.expires_at > ? AND s.absolute_expires_at > ? AND s.last_used_at > ?))`,
		input.AccountID, formatTime(now.Add(-input.ActiveWindow)), nowText, nowText, s.idleCutoff(now)).Scan(&active); err != nil {
		return RecoveryClaimResult{}, err
	}
	readyAt := now
	if active {
		readyAt = now.Add(input.Wait)
	}
	result := RecoveryClaimResult{ActiveDeviceSeen: active}
	result.ReplacedRequest, result.ReplacedEventID, err = cancelWaitingRecoveryRequestTx(ctx, tx, input.AccountID, RecoveryCancelledReplaced, nowText)
	if err != nil {
		return RecoveryClaimResult{}, err
	}
	id, err := domain.NewID("rcv")
	if err != nil {
		return RecoveryClaimResult{}, err
	}
	request := RecoveryRequest{
		ID: id, AccountID: input.AccountID, DeviceID: reservation.DeviceID,
		DeviceName: strings.TrimSpace(input.DeviceName), State: RecoveryStateWaiting,
		CreatedAt: now, ReadyAt: readyAt, ExpiresAt: readyAt.Add(RecoveryRequestUnclaimedLifetime),
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO account_recovery_requests(id, account_id, device_id, device_name, key_package, signing_key,
		  device_auth_hash, claim_token_hash, verified_password_hash, verified_auth_key, state, created_at, ready_at, expires_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'waiting', ?, ?, ?)`,
		request.ID, request.AccountID, request.DeviceID, request.DeviceName, input.KeyPackage, input.SigningKey,
		input.DeviceAuthHash, input.ClaimTokenHash, input.VerifiedPasswordHash, input.VerifiedAuthKey,
		nowText, formatTime(request.ReadyAt), formatTime(request.ExpiresAt)); err != nil {
		return RecoveryClaimResult{}, err
	}
	result.PendingEventID, err = insertSyncEvent(ctx, tx, recoveryPendingEventType, &request.AccountID, "", recoveryPendingPayload(request), nowText)
	if err != nil {
		return RecoveryClaimResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return RecoveryClaimResult{}, err
	}
	result.Request = request
	return result, nil
}

func recoveryPendingPayload(request RecoveryRequest) map[string]interface{} {
	return map[string]interface{}{"request_id": request.ID, "device_name": request.DeviceName, "ready_at": request.ReadyAt}
}

// RecoveryCompletion is the answer to a status call.
type RecoveryCompletion struct {
	State   string
	ReadyAt time.Time
	Account domain.Account
	Device  domain.Device
	// SessionIssued is true only for the call whose transaction completed
	// the request and stored the session token hash it was given.
	SessionIssued bool
	// RevokedDevices and RevokedEventIDs are the old devices this
	// completion revoked and their device.revoked sync events.
	RevokedDevices   []string
	RevokedEventIDs  []int64
	RecoveredEventID int64
}

type recoveryRequestRecord struct {
	RecoveryRequest
	keyPackage           []byte
	signingKey           []byte
	deviceAuthHash       string
	verifiedPasswordHash string
	verifiedAuthKey      []byte
	completedAt          sql.NullString
}

// CompleteRecovery answers a status call for the request id held by the
// claim token. A waiting request before ready_at answers "waiting". When it
// is ready, one transaction checks that the account is active and that its
// password hash and recovery key still equal the verified copies, revokes
// every old device (each with revokeDeviceTx), and only then inserts the new
// device, its first key package and a session for sessionTokenHash. That
// session has no recent authentication. A completed request answers
// "completed" again without a session (the lost-200 case). A cancelled,
// expired or no longer valid request returns ErrRecoveryCancelled, and an
// unknown id or wrong token ErrNotFound.
func (s *Store) CompleteRecovery(ctx context.Context, id, claimTokenHash, sessionTokenHash string) (RecoveryCompletion, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RecoveryCompletion{}, err
	}
	defer tx.Rollback()
	var record recoveryRequestRecord
	var createdAt, readyAt, expiresAt string
	err = tx.QueryRowContext(ctx, `
		SELECT id, account_id, device_id, device_name, key_package, signing_key, device_auth_hash,
		  verified_password_hash, verified_auth_key, state, created_at, ready_at, expires_at, completed_at
		FROM account_recovery_requests WHERE id = ? AND claim_token_hash = ?`,
		strings.TrimSpace(id), claimTokenHash).Scan(
		&record.ID, &record.AccountID, &record.DeviceID, &record.DeviceName, &record.keyPackage, &record.signingKey,
		&record.deviceAuthHash, &record.verifiedPasswordHash, &record.verifiedAuthKey, &record.State,
		&createdAt, &readyAt, &expiresAt, &record.completedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return RecoveryCompletion{}, ErrNotFound
	}
	if err != nil {
		return RecoveryCompletion{}, err
	}
	record.CreatedAt, record.ReadyAt, record.ExpiresAt = parseTime(createdAt), parseTime(readyAt), parseTime(expiresAt)
	now := time.Now().UTC()
	nowText := formatTime(now)
	switch record.State {
	case RecoveryStateCompleted:
		return s.completedRecovery(ctx, tx, record)
	case RecoveryStateWaiting:
	default:
		return RecoveryCompletion{}, ErrRecoveryCancelled
	}
	if !record.ExpiresAt.After(now) {
		if _, err := tx.ExecContext(ctx, `UPDATE account_recovery_requests SET state = 'expired' WHERE id = ? AND state = 'waiting'`, record.ID); err != nil {
			return RecoveryCompletion{}, err
		}
		if err := tx.Commit(); err != nil {
			return RecoveryCompletion{}, err
		}
		return RecoveryCompletion{}, ErrRecoveryCancelled
	}
	if record.ReadyAt.After(now) {
		return RecoveryCompletion{State: RecoveryStateWaiting, ReadyAt: record.ReadyAt}, nil
	}
	var passwordHash string
	var authKey []byte
	err = tx.QueryRowContext(ctx, `
		SELECT a.password_hash, k.auth_public_key FROM accounts a
		LEFT JOIN account_recovery_keys k ON k.account_id = a.id
		WHERE a.id = ? AND a.status = 'active' AND a.deleted_at IS NULL`, record.AccountID).Scan(&passwordHash, &authKey)
	if errors.Is(err, sql.ErrNoRows) {
		// Suspended or deleted: the same 410, and nothing changes, so an
		// account an admin reactivates can still finish.
		return RecoveryCompletion{}, ErrRecoveryCancelled
	}
	if err != nil {
		return RecoveryCompletion{}, err
	}
	// The backstop behind cancel-on-change: credentials that moved void the
	// request (a rehash moves the verified hash with it).
	if passwordHash != record.verifiedPasswordHash || !bytes.Equal(authKey, record.verifiedAuthKey) {
		if _, err := tx.ExecContext(ctx, `UPDATE account_recovery_requests SET state = 'cancelled', cancelled_by = ? WHERE id = ? AND state = 'waiting'`, RecoveryCancelledCredentialsMoved, record.ID); err != nil {
			return RecoveryCompletion{}, err
		}
		if err := tx.Commit(); err != nil {
			return RecoveryCompletion{}, err
		}
		return RecoveryCompletion{}, ErrRecoveryCancelled
	}
	oldDevices, err := activeDeviceIDsTx(ctx, tx, record.AccountID)
	if err != nil {
		return RecoveryCompletion{}, err
	}
	completion := RecoveryCompletion{State: RecoveryStateCompleted, ReadyAt: record.ReadyAt, SessionIssued: true, RevokedDevices: oldDevices}
	// Every old device is revoked before the new one exists, so the new
	// device (no MLS leaf yet) can never be elected coordinator of, or be
	// snapshotted as a required confirmer for, these revocations. All of
	// them are marked revoked first, as account deletion does: then no old
	// device is recorded as coordinator of a sibling's revocation, which
	// would hand the role, once that sibling is revoked too, to the lowest
	// eligible device of a legacy group, possibly the new one.
	if _, err := tx.ExecContext(ctx, `UPDATE devices SET revoked_at = ? WHERE account_id = ? AND revoked_at IS NULL`, nowText, record.AccountID); err != nil {
		return RecoveryCompletion{}, err
	}
	for _, deviceID := range oldDevices {
		eventID, err := revokeDeviceTx(ctx, tx, record.AccountID, deviceID, "device.revoked", nowText)
		if err != nil {
			return RecoveryCompletion{}, err
		}
		completion.RevokedEventIDs = append(completion.RevokedEventIDs, eventID)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)`,
		record.DeviceID, record.AccountID, record.DeviceName, record.keyPackage, record.signingKey, record.deviceAuthHash, nowText); err != nil {
		return RecoveryCompletion{}, err
	}
	if err := insertInitialDeviceKeyPackage(ctx, tx, record.DeviceID, record.keyPackage, nowText); err != nil {
		return RecoveryCompletion{}, err
	}
	// No recent_auth_at: the forced changes after recovery need a reauth
	// with the password and the claim's device secret.
	idleExpiry, absoluteExpiry := s.sessionLifetime(now, time.Time{})
	if _, err := tx.ExecContext(ctx, `INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at) VALUES(?, ?, ?, ?, ?, NULL, ?, ?)`,
		sessionTokenHash, record.AccountID, record.DeviceID, idleExpiry, nowText, nowText, absoluteExpiry); err != nil {
		return RecoveryCompletion{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE account_recovery_requests SET state = 'completed', completed_at = ? WHERE id = ? AND state = 'waiting'`, nowText, record.ID); err != nil {
		return RecoveryCompletion{}, err
	}
	revoked := oldDevices
	if revoked == nil {
		revoked = []string{}
	}
	completion.RecoveredEventID, err = insertSyncEvent(ctx, tx, recoveryRecoveredEventType, &record.AccountID, "", map[string]interface{}{"device_id": record.DeviceID, "revoked": revoked}, nowText)
	if err != nil {
		return RecoveryCompletion{}, err
	}
	if err := insertAuditEvent(ctx, tx, &record.AccountID, "account.recovered", map[string]interface{}{"request_id": record.ID, "device_id": record.DeviceID, "revoked": revoked}); err != nil {
		return RecoveryCompletion{}, err
	}
	record.completedAt = sql.NullString{String: nowText, Valid: true}
	result, err := s.completedRecovery(ctx, tx, record)
	if err != nil {
		return RecoveryCompletion{}, err
	}
	completion.Account, completion.Device = result.Account, result.Device
	if err := tx.Commit(); err != nil {
		return RecoveryCompletion{}, err
	}
	return completion, nil
}

// completedRecovery loads the account and device of a completed request.
func (s *Store) completedRecovery(ctx context.Context, tx *sql.Tx, record recoveryRequestRecord) (RecoveryCompletion, error) {
	completion := RecoveryCompletion{State: RecoveryStateCompleted, ReadyAt: record.ReadyAt}
	var email, deleted sql.NullString
	var created string
	if err := tx.QueryRowContext(ctx, `SELECT id, username, email, role, status, created_at, deleted_at FROM accounts WHERE id = ?`, record.AccountID).
		Scan(&completion.Account.ID, &completion.Account.Username, &email, &completion.Account.Role, &completion.Account.Status, &created, &deleted); err != nil {
		return RecoveryCompletion{}, err
	}
	completion.Account.Email = stringPtr(email)
	completion.Account.CreatedAt = parseTime(created)
	completion.Account.DeletedAt = parseOptionalTime(deleted)
	var deviceCreated string
	var revokedAt sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT id, account_id, name, key_package, signing_key, created_at, revoked_at FROM devices WHERE id = ? AND account_id = ?`, record.DeviceID, record.AccountID).
		Scan(&completion.Device.ID, &completion.Device.AccountID, &completion.Device.Name, &completion.Device.KeyPackage, &completion.Device.SigningKey, &deviceCreated, &revokedAt); err != nil {
		return RecoveryCompletion{}, err
	}
	completion.Device.CreatedAt = parseTime(deviceCreated)
	completion.Device.RevokedAt = parseOptionalTime(revokedAt)
	return completion, nil
}

func activeDeviceIDsTx(ctx context.Context, tx *sql.Tx, accountID string) ([]string, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id FROM devices WHERE account_id = ? AND revoked_at IS NULL ORDER BY id`, accountID)
	if err != nil {
		return nil, err
	}
	var ids []string
	if err := eachRow(rows, func(rows rowIterator) error {
		var id string
		if err := rows.Scan(&id); err != nil {
			return err
		}
		ids = append(ids, id)
		return nil
	}); err != nil {
		return nil, err
	}
	return ids, nil
}

// CancelRecoveryRequest cancels the account's waiting request id. It returns
// the account.recovery.cancelled sync event, or ErrNotFound when the account
// has no such waiting request.
func (s *Store) CancelRecoveryRequest(ctx context.Context, accountID, id string) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var waitingID string
	err = tx.QueryRowContext(ctx, `SELECT id FROM account_recovery_requests WHERE id = ? AND account_id = ? AND state = 'waiting'`, strings.TrimSpace(id), accountID).Scan(&waitingID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	_, eventID, err := cancelWaitingRecoveryRequestTx(ctx, tx, accountID, RecoveryCancelledByOwner, nowString())
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
}

// cancelWaitingRecoveryTx cancels the account's waiting recovery request, if
// any, in the caller's transaction, with its sync event and audit entry. A
// password change, an owner password reset and a recovery key change call
// it, so a request whose credentials moved never waits on.
func cancelWaitingRecoveryTx(ctx context.Context, tx *sql.Tx, accountID, reason, now string) (int64, error) {
	requestID, eventID, err := cancelWaitingRecoveryRequestTx(ctx, tx, accountID, reason, now)
	if err != nil || requestID == "" {
		return 0, err
	}
	if err := insertAuditEvent(ctx, tx, &accountID, "account.recovery_cancelled", map[string]string{"request_id": requestID, "reason": reason}); err != nil {
		return 0, err
	}
	return eventID, nil
}

func cancelWaitingRecoveryRequestTx(ctx context.Context, tx *sql.Tx, accountID, reason, now string) (string, int64, error) {
	var requestID string
	err := tx.QueryRowContext(ctx, `SELECT id FROM account_recovery_requests WHERE account_id = ? AND state = 'waiting'`, accountID).Scan(&requestID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, nil
	}
	if err != nil {
		return "", 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE account_recovery_requests SET state = 'cancelled', cancelled_by = ? WHERE id = ? AND state = 'waiting'`, reason, requestID); err != nil {
		return "", 0, err
	}
	eventID, err := insertSyncEvent(ctx, tx, recoveryCancelledEventType, &accountID, "", map[string]string{"request_id": requestID, "reason": reason}, now)
	if err != nil {
		return "", 0, err
	}
	return requestID, eventID, nil
}

// RecoveryKeyResult is what SetRecoveryKey committed.
type RecoveryKeyResult struct {
	EventID          int64
	CancelledEventID int64
}

// SetRecoveryKey sets or replaces the account's recovery key verifier and,
// in the same transaction, cancels a waiting recovery request.
func (s *Store) SetRecoveryKey(ctx context.Context, accountID string, authPublicKey, rkID []byte) (RecoveryKeyResult, error) {
	if len(authPublicKey) != 32 || len(rkID) != 16 {
		return RecoveryKeyResult{}, ErrInvalidInput
	}
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RecoveryKeyResult{}, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		INSERT INTO account_recovery_keys(account_id, auth_public_key, rk_id, created_at)
		SELECT id, ?, ?, ? FROM accounts WHERE id = ? AND status = 'active' AND deleted_at IS NULL
		ON CONFLICT(account_id) DO UPDATE SET auth_public_key = excluded.auth_public_key, rk_id = excluded.rk_id, created_at = excluded.created_at`,
		authPublicKey, rkID, now, accountID)
	if err != nil {
		return RecoveryKeyResult{}, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return RecoveryKeyResult{}, ErrNotFound
	}
	var out RecoveryKeyResult
	if out.CancelledEventID, err = cancelWaitingRecoveryTx(ctx, tx, accountID, RecoveryCancelledKeyChanged, now); err != nil {
		return RecoveryKeyResult{}, err
	}
	if out.EventID, err = insertSyncEvent(ctx, tx, recoveryKeySetEventType, &accountID, "", map[string]interface{}{"rk_id": rkID}, now); err != nil {
		return RecoveryKeyResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return RecoveryKeyResult{}, err
	}
	return out, nil
}

// RecoveryKeyStatus is the account's recovery setup as GET reports it.
type RecoveryKeyStatus struct {
	Configured bool
	RKID       []byte
	SetAt      *time.Time
	Pending    *RecoveryRequest
}

func (s *Store) RecoveryKeyStatus(ctx context.Context, accountID string) (RecoveryKeyStatus, error) {
	var status RecoveryKeyStatus
	var created string
	err := s.db.QueryRowContext(ctx, `SELECT rk_id, created_at FROM account_recovery_keys WHERE account_id = ?`, accountID).Scan(&status.RKID, &created)
	switch {
	case err == nil:
		status.Configured = true
		setAt := parseTime(created)
		status.SetAt = &setAt
	case !errors.Is(err, sql.ErrNoRows):
		return RecoveryKeyStatus{}, err
	}
	var request RecoveryRequest
	var requestCreated, readyAt, expiresAt string
	err = s.db.QueryRowContext(ctx, `SELECT id, account_id, device_id, device_name, state, created_at, ready_at, expires_at FROM account_recovery_requests WHERE account_id = ? AND state = 'waiting' AND expires_at > ?`, accountID, nowString()).
		Scan(&request.ID, &request.AccountID, &request.DeviceID, &request.DeviceName, &request.State, &requestCreated, &readyAt, &expiresAt)
	switch {
	case err == nil:
		request.CreatedAt, request.ReadyAt, request.ExpiresAt = parseTime(requestCreated), parseTime(readyAt), parseTime(expiresAt)
		status.Pending = &request
	case !errors.Is(err, sql.ErrNoRows):
		return RecoveryKeyStatus{}, err
	}
	return status, nil
}
