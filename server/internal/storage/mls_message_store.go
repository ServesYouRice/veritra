package storage

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

type CreateMLSMessageInput struct {
	ConversationID     string
	SenderAccountID    string
	SenderDeviceID     string
	RecipientDeviceID  string
	RevocationDeviceID string
	Kind               string
	Payload            []byte
	IdempotencyKey     string
}

func (s *Store) CreateMLSMessage(ctx context.Context, input CreateMLSMessageInput) (domain.MLSMessage, bool, error) {
	input.ConversationID = strings.TrimSpace(input.ConversationID)
	input.RecipientDeviceID = strings.TrimSpace(input.RecipientDeviceID)
	input.RevocationDeviceID = strings.TrimSpace(input.RevocationDeviceID)
	input.Kind = strings.TrimSpace(input.Kind)
	input.IdempotencyKey = strings.TrimSpace(input.IdempotencyKey)
	if input.ConversationID == "" || input.SenderAccountID == "" || input.SenderDeviceID == "" ||
		(input.Kind != "welcome" && input.Kind != "commit") || len(input.Payload) == 0 || len(input.Payload) > 4*1024*1024 ||
		input.IdempotencyKey == "" || len(input.IdempotencyKey) > 128 ||
		(input.Kind == "welcome" && input.RecipientDeviceID == "") || input.RecipientDeviceID == input.SenderDeviceID ||
		(input.RevocationDeviceID != "" && (input.Kind != "commit" || input.RecipientDeviceID != "")) {
		return domain.MLSMessage{}, false, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.MLSMessage{}, false, err
	}
	defer tx.Rollback()

	var member bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(
		SELECT 1 FROM memberships m JOIN devices d ON d.account_id = m.account_id
		WHERE m.conversation_id = ? AND m.account_id = ? AND d.id = ? AND d.revoked_at IS NULL
	)`, input.ConversationID, input.SenderAccountID, input.SenderDeviceID).Scan(&member); err != nil {
		return domain.MLSMessage{}, false, err
	}
	if !member {
		return domain.MLSMessage{}, false, ErrNotMember
	}

	existing, err := scanMLSMessage(tx.QueryRowContext(ctx, `
		SELECT id, conversation_id, sender_account_id, sender_device_id, recipient_device_id, revocation_device_id,
		       kind, payload, idempotency_key, sync_event_id, created_at
		FROM conversation_mls_messages WHERE sender_device_id = ? AND idempotency_key = ?`,
		input.SenderDeviceID, input.IdempotencyKey))
	if err == nil {
		if existing.ConversationID != input.ConversationID || existing.Kind != input.Kind ||
			existing.RecipientDeviceID != input.RecipientDeviceID || existing.RevocationDeviceID != input.RevocationDeviceID ||
			!bytes.Equal(existing.Payload, input.Payload) {
			return domain.MLSMessage{}, false, ErrIdempotencyConflict
		}
		return existing, true, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return domain.MLSMessage{}, false, err
	}
	if input.RevocationDeviceID != "" {
		var allowed bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(
			SELECT 1 FROM mls_revocations WHERE conversation_id = ? AND revoked_device_id = ?
			AND coordinator_device_id = ? AND state = 'pending')`, input.ConversationID,
			input.RevocationDeviceID, input.SenderDeviceID).Scan(&allowed); err != nil {
			return domain.MLSMessage{}, false, err
		}
		if !allowed {
			return domain.MLSMessage{}, false, ErrForbidden
		}
	}

	var recipientAccountID *string
	if input.RecipientDeviceID != "" {
		var accountID string
		err := tx.QueryRowContext(ctx, `
			SELECT d.account_id FROM devices d
			JOIN memberships m ON m.account_id = d.account_id
			WHERE d.id = ? AND d.revoked_at IS NULL AND m.conversation_id = ?`,
			input.RecipientDeviceID, input.ConversationID).Scan(&accountID)
		if errors.Is(err, sql.ErrNoRows) {
			return domain.MLSMessage{}, false, ErrForbidden
		}
		if err != nil {
			return domain.MLSMessage{}, false, err
		}
		recipientAccountID = &accountID
	}

	id, err := domain.NewID("mls")
	if err != nil {
		return domain.MLSMessage{}, false, err
	}
	createdAt := time.Now().UTC()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO conversation_mls_messages(
			id, conversation_id, sender_account_id, sender_device_id, recipient_device_id,
			kind, payload, idempotency_key, created_at, revocation_device_id
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, input.ConversationID, input.SenderAccountID, input.SenderDeviceID,
		nullableEmptyString(input.RecipientDeviceID), input.Kind, input.Payload,
		input.IdempotencyKey, formatTime(createdAt), nullableEmptyString(input.RevocationDeviceID)); err != nil {
		return domain.MLSMessage{}, false, err
	}
	eventID, err := insertSyncEvent(ctx, tx, "mls.message.created", recipientAccountID,
		input.ConversationID, map[string]string{"mls_message_id": id, "kind": input.Kind}, formatTime(createdAt))
	if err != nil {
		return domain.MLSMessage{}, false, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE conversation_mls_messages SET sync_event_id = ? WHERE id = ?`, eventID, id); err != nil {
		return domain.MLSMessage{}, false, err
	}
	if input.RevocationDeviceID != "" {
		if _, err := tx.ExecContext(ctx, `UPDATE mls_revocations SET state = 'commit_submitted', commit_message_id = ?
			WHERE conversation_id = ? AND revoked_device_id = ? AND state = 'pending'`,
			id, input.ConversationID, input.RevocationDeviceID); err != nil {
			return domain.MLSMessage{}, false, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE mls_revocation_required_devices SET confirmed_at = ?
			WHERE conversation_id = ? AND revoked_device_id = ? AND device_id = ?`,
			formatTime(createdAt), input.ConversationID, input.RevocationDeviceID, input.SenderDeviceID); err != nil {
			return domain.MLSMessage{}, false, err
		}
		if err := completeMLSRevocationIfConfirmed(ctx, tx, input.ConversationID, input.RevocationDeviceID, createdAt); err != nil {
			return domain.MLSMessage{}, false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.MLSMessage{}, false, err
	}
	return domain.MLSMessage{
		ID: id, ConversationID: input.ConversationID, SenderAccountID: input.SenderAccountID,
		SenderDeviceID: input.SenderDeviceID, RecipientDeviceID: input.RecipientDeviceID,
		RevocationDeviceID: input.RevocationDeviceID,
		Kind:               input.Kind, Payload: input.Payload, IdempotencyKey: input.IdempotencyKey,
		SyncEventID: eventID, CreatedAt: createdAt,
	}, false, nil
}

func (s *Store) MLSMessage(ctx context.Context, id, accountID, deviceID string) (domain.MLSMessage, error) {
	message, err := scanMLSMessage(s.db.QueryRowContext(ctx, `
		SELECT mm.id, mm.conversation_id, mm.sender_account_id, mm.sender_device_id,
		       mm.recipient_device_id, mm.revocation_device_id, mm.kind, mm.payload, mm.idempotency_key,
		       mm.sync_event_id, mm.created_at
		FROM conversation_mls_messages mm
		JOIN memberships m ON m.conversation_id = mm.conversation_id AND m.account_id = ?
		WHERE mm.id = ? AND (mm.recipient_device_id IS NULL OR mm.recipient_device_id = ?)`,
		accountID, id, deviceID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.MLSMessage{}, ErrNotFound
	}
	return message, err
}

func (s *Store) ListMLSMessages(ctx context.Context, accountID, deviceID string, afterEventID int64, limit int) ([]domain.MLSMessage, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT mm.id, mm.conversation_id, mm.sender_account_id, mm.sender_device_id,
		       mm.recipient_device_id, mm.revocation_device_id, mm.kind, mm.payload, mm.idempotency_key,
		       mm.sync_event_id, mm.created_at
		FROM conversation_mls_messages mm
		JOIN memberships m ON m.conversation_id = mm.conversation_id AND m.account_id = ?
		WHERE mm.sync_event_id > ? AND (mm.recipient_device_id IS NULL OR mm.recipient_device_id = ?)
		ORDER BY mm.sync_event_id LIMIT ?`, accountID, afterEventID, deviceID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]domain.MLSMessage, 0)
	for rows.Next() {
		message, err := scanMLSMessage(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, message)
	}
	return result, rows.Err()
}

type mlsMessageScanner interface {
	Scan(...any) error
}

func scanMLSMessage(scanner mlsMessageScanner) (domain.MLSMessage, error) {
	var message domain.MLSMessage
	var recipient sql.NullString
	var revocation sql.NullString
	var createdAt string
	err := scanner.Scan(&message.ID, &message.ConversationID, &message.SenderAccountID,
		&message.SenderDeviceID, &recipient, &revocation, &message.Kind, &message.Payload,
		&message.IdempotencyKey, &message.SyncEventID, &createdAt)
	if err != nil {
		return domain.MLSMessage{}, err
	}
	message.RecipientDeviceID = recipient.String
	message.RevocationDeviceID = revocation.String
	message.CreatedAt = parseTime(createdAt)
	return message, nil
}

func completeMLSRevocationIfConfirmed(ctx context.Context, tx *sql.Tx, conversationID, revokedDeviceID string, now time.Time) error {
	var remaining int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM mls_revocation_required_devices
		WHERE conversation_id = ? AND revoked_device_id = ? AND confirmed_at IS NULL`,
		conversationID, revokedDeviceID).Scan(&remaining); err != nil {
		return err
	}
	if remaining == 0 {
		_, err := tx.ExecContext(ctx, `UPDATE mls_revocations SET state = 'completed', completed_at = ?
			WHERE conversation_id = ? AND revoked_device_id = ? AND state = 'commit_submitted'`,
			formatTime(now), conversationID, revokedDeviceID)
		return err
	}
	return nil
}
