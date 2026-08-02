package storage

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
)

func (s *Store) ListMLSRevocations(ctx context.Context, accountID, deviceID string) ([]domain.MLSRevocation, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT r.conversation_id, r.revoked_device_id, r.revoked_account_id,
		       r.coordinator_device_id, r.state, r.commit_message_id,
		       r.requested_at, r.completed_at
		FROM mls_revocations r
		JOIN memberships m ON m.conversation_id = r.conversation_id AND m.account_id = ?
		JOIN mls_revocation_required_devices rd ON rd.conversation_id = r.conversation_id
		 AND rd.revoked_device_id = r.revoked_device_id AND rd.device_id = ?
		WHERE r.state <> 'completed' AND rd.confirmed_at IS NULL
		ORDER BY r.requested_at, r.conversation_id`, accountID, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]domain.MLSRevocation, 0)
	for rows.Next() {
		var item domain.MLSRevocation
		var messageID, completedAt sql.NullString
		var requestedAt string
		if err := rows.Scan(&item.ConversationID, &item.RevokedDeviceID,
			&item.RevokedAccountID, &item.CoordinatorDeviceID, &item.State,
			&messageID, &requestedAt, &completedAt); err != nil {
			return nil, err
		}
		if messageID.Valid {
			item.CommitMessageID = &messageID.String
		}
		item.RequestedAt = parseTime(requestedAt)
		if completedAt.Valid {
			value := parseTime(completedAt.String)
			item.CompletedAt = &value
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) ConfirmMLSRevocation(ctx context.Context, conversationID, revokedDeviceID, accountID, deviceID string) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE mls_revocation_required_devices
		SET confirmed_at = COALESCE(confirmed_at, ?)
		WHERE conversation_id = ? AND revoked_device_id = ? AND device_id = ?
		AND confirmed_at IS NULL
		AND EXISTS (SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?)
		AND EXISTS (SELECT 1 FROM mls_revocations WHERE conversation_id = ?
			AND revoked_device_id = ? AND state = 'commit_submitted')`,
		nowString(), conversationID, revokedDeviceID, deviceID,
		conversationID, accountID, conversationID, revokedDeviceID)
	if err != nil {
		return 0, err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if changed == 0 {
		var exists bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM mls_revocation_required_devices
			WHERE conversation_id = ? AND revoked_device_id = ? AND device_id = ? AND confirmed_at IS NOT NULL)`,
			conversationID, revokedDeviceID, deviceID).Scan(&exists); err != nil {
			return 0, err
		}
		if !exists {
			return 0, ErrForbidden
		}
		if err := tx.Commit(); err != nil {
			return 0, err
		}
		return 0, nil
	}
	now := time.Now().UTC()
	if err := completeMLSRevocationIfConfirmed(ctx, tx, conversationID, revokedDeviceID, now); err != nil {
		return 0, err
	}
	var completed bool
	if err := tx.QueryRowContext(ctx, `SELECT state = 'completed' FROM mls_revocations
		WHERE conversation_id = ? AND revoked_device_id = ?`, conversationID, revokedDeviceID).Scan(&completed); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrNotFound
		}
		return 0, err
	}
	var eventID int64
	if completed {
		eventID, err = insertSyncEvent(ctx, tx, "mls.revocation.completed", nil,
			conversationID, map[string]string{"device_id": revokedDeviceID}, formatTime(now))
		if err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
}
