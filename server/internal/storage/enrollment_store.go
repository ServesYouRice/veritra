package storage

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/binary"
	"errors"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

const enrollmentLifetime = 10 * time.Minute

type EnrollmentReservation struct {
	ID        string
	Kind      string
	AccountID string
	DeviceID  string
	InviteID  *string
	Challenge []byte
	ExpiresAt time.Time
}

func (s *Store) ReserveOwnerEnrollment(ctx context.Context) (EnrollmentReservation, error) {
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts`).Scan(&count); err != nil {
		return EnrollmentReservation{}, err
	}
	if count != 0 {
		return EnrollmentReservation{}, ErrAlreadySetup
	}
	return s.createEnrollmentReservation(ctx, "owner", nil)
}

func (s *Store) ReserveRegistrationEnrollment(ctx context.Context, inviteCode string) (EnrollmentReservation, error) {
	var inviteID string
	err := s.db.QueryRowContext(ctx, `
		SELECT id FROM invites
		WHERE code = ? AND revoked_at IS NULL AND uses < max_uses
		  AND (expires_at IS NULL OR expires_at > ?)`,
		strings.TrimSpace(inviteCode), nowString()).Scan(&inviteID)
	if errors.Is(err, sql.ErrNoRows) {
		return EnrollmentReservation{}, ErrInviteInvalid
	}
	if err != nil {
		return EnrollmentReservation{}, err
	}
	return s.createEnrollmentReservation(ctx, "register", &inviteID)
}

func (s *Store) createEnrollmentReservation(ctx context.Context, kind string, inviteID *string) (EnrollmentReservation, error) {
	id, err := domain.NewID("enroll")
	if err != nil {
		return EnrollmentReservation{}, err
	}
	accountID, err := domain.NewID("acct")
	if err != nil {
		return EnrollmentReservation{}, err
	}
	deviceID, err := domain.NewID("dev")
	if err != nil {
		return EnrollmentReservation{}, err
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return EnrollmentReservation{}, err
	}
	challenge := encodeEnrollmentChallenge(id, accountID, deviceID, nonce)
	now := time.Now().UTC()
	expiresAt := now.Add(enrollmentLifetime)
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO enrollment_reservations(
		  id, kind, account_id, device_id, invite_id, challenge, created_at, expires_at
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		id, kind, accountID, deviceID, nullableString(inviteID), challenge,
		formatTime(now), formatTime(expiresAt))
	if err != nil {
		return EnrollmentReservation{}, err
	}
	return EnrollmentReservation{
		ID: id, Kind: kind, AccountID: accountID, DeviceID: deviceID,
		InviteID: inviteID, Challenge: challenge, ExpiresAt: expiresAt,
	}, nil
}

func (s *Store) EnrollmentReservation(ctx context.Context, id string) (EnrollmentReservation, error) {
	return scanEnrollmentReservation(s.db.QueryRowContext(ctx, `
		SELECT id, kind, account_id, device_id, invite_id, challenge, expires_at
		FROM enrollment_reservations
		WHERE id = ? AND consumed_at IS NULL AND expires_at > ?`,
		strings.TrimSpace(id), nowString()))
}

func enrollmentReservationForTx(ctx context.Context, tx *sql.Tx, id, kind string) (EnrollmentReservation, error) {
	reservation, err := scanEnrollmentReservation(tx.QueryRowContext(ctx, `
		SELECT id, kind, account_id, device_id, invite_id, challenge, expires_at
		FROM enrollment_reservations
		WHERE id = ? AND kind = ? AND consumed_at IS NULL AND expires_at > ?`,
		strings.TrimSpace(id), kind, nowString()))
	if errors.Is(err, sql.ErrNoRows) {
		return EnrollmentReservation{}, ErrEnrollmentInvalid
	}
	return reservation, err
}

func consumeEnrollmentReservation(ctx context.Context, tx *sql.Tx, id string) error {
	result, err := tx.ExecContext(ctx, `
		UPDATE enrollment_reservations SET consumed_at = ?
		WHERE id = ? AND consumed_at IS NULL AND expires_at > ?`,
		nowString(), id, nowString())
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return ErrEnrollmentInvalid
	}
	return nil
}

func scanEnrollmentReservation(row scanner) (EnrollmentReservation, error) {
	var reservation EnrollmentReservation
	var inviteID sql.NullString
	var expiresAt string
	err := row.Scan(
		&reservation.ID, &reservation.Kind, &reservation.AccountID,
		&reservation.DeviceID, &inviteID, &reservation.Challenge, &expiresAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return EnrollmentReservation{}, ErrEnrollmentInvalid
	}
	if err != nil {
		return EnrollmentReservation{}, err
	}
	reservation.InviteID = stringPtr(inviteID)
	reservation.ExpiresAt = parseTime(expiresAt)
	return reservation, nil
}

func encodeEnrollmentChallenge(reservationID, accountID, deviceID string, nonce []byte) []byte {
	output := []byte("veritra-enrollment-v1")
	for _, value := range [][]byte{[]byte(reservationID), []byte(accountID), []byte(deviceID), nonce} {
		var size [2]byte
		binary.BigEndian.PutUint16(size[:], uint16(len(value)))
		output = append(output, size[:]...)
		output = append(output, value...)
	}
	return output
}
