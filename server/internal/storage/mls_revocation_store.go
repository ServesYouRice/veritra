package storage

import (
	"context"
	"database/sql"
	"time"

	"private-messenger/server/internal/domain"
)

// mlsRevocationEligibleDevice is true when device (SQL text: a column) may
// commit revocation r (SQL text: a table alias): it is not the revoked
// device, it is not revoked itself, its account is a member of the
// conversation and, in a rostered group (card I51), it is an active group
// device.
func mlsRevocationEligibleDevice(r, device string) string {
	return `EXISTS (SELECT 1 FROM devices ed
		JOIN memberships em ON em.account_id = ed.account_id AND em.conversation_id = ` + r + `.conversation_id
		WHERE ed.id = ` + device + ` AND ed.revoked_at IS NULL AND ed.id <> ` + r + `.revoked_device_id
		  AND (NOT EXISTS (SELECT 1 FROM conversation_mls_groups eg WHERE eg.conversation_id = ` + r + `.conversation_id)
		       OR EXISTS (SELECT 1 FROM conversation_mls_devices er WHERE er.conversation_id = ` + r + `.conversation_id
		                  AND er.device_id = ed.id AND er.removed_after_event_id IS NULL)))`
}

// mlsRevocationCoordinator is the device expected to commit revocation r
// (SQL text: a table alias). It is the coordinator recorded when the
// revocation was queued while that device can still commit it. Once it
// cannot (it was revoked, its account left the conversation or was deleted,
// or it left the group), the lowest eligible device id takes over, so a
// revocation never waits for good on a device that will not act. It is NULL
// only when no device is eligible. One device is named at any moment, so
// group devices do not race for the commit; the epoch check is what keeps
// two commits from both landing.
func mlsRevocationCoordinator(r string) string {
	return `(CASE WHEN ` + mlsRevocationEligibleDevice(r, r+`.coordinator_device_id`) + `
		THEN ` + r + `.coordinator_device_id
		ELSE (SELECT MIN(cd.id) FROM devices cd
			JOIN memberships cm ON cm.account_id = cd.account_id
			WHERE cm.conversation_id = ` + r + `.conversation_id
			  AND ` + mlsRevocationEligibleDevice(r, `cd.id`) + `) END)`
}

// mlsRevocationCommitAllowed reports whether device may submit the commit for
// the pending revocation of revokedDeviceID: only its current coordinator
// (mlsRevocationCoordinator) may.
func mlsRevocationCommitAllowed(ctx context.Context, q rowQuerier, conversationID, revokedDeviceID, deviceID string) (bool, error) {
	var allowed bool
	err := q.QueryRowContext(ctx, `SELECT EXISTS(
		SELECT 1 FROM mls_revocations r WHERE r.conversation_id = ? AND r.revoked_device_id = ?
		AND r.state = 'pending' AND `+mlsRevocationCoordinator("r")+` = ?)`,
		conversationID, revokedDeviceID, deviceID).Scan(&allowed)
	return allowed, err
}

// ListMLSRevocations returns the revocations the device still has to act on:
// those it must confirm, and a pending one it coordinates now, even when it
// joined the group after the revocation was queued. coordinator_device_id is
// the current coordinator (mlsRevocationCoordinator), which the client
// compares with its own device id before it commits.
func (s *Store) ListMLSRevocations(ctx context.Context, accountID, deviceID string) ([]domain.MLSRevocation, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT conversation_id, revoked_device_id, revoked_account_id,
		       COALESCE(coordinator, coordinator_device_id), state, commit_message_id,
		       requested_at, completed_at
		FROM (
			SELECT r.conversation_id, r.revoked_device_id, r.revoked_account_id,
			       r.coordinator_device_id, r.state, r.commit_message_id,
			       r.requested_at, r.completed_at,
			       CASE WHEN r.state = 'pending' THEN `+mlsRevocationCoordinator("r")+` END AS coordinator,
			       rd.device_id AS required_device_id, rd.confirmed_at AS confirmed_at
			FROM mls_revocations r
			JOIN memberships m ON m.conversation_id = r.conversation_id AND m.account_id = ?1
			LEFT JOIN mls_revocation_required_devices rd ON rd.conversation_id = r.conversation_id
			 AND rd.revoked_device_id = r.revoked_device_id AND rd.device_id = ?2
			WHERE r.state <> 'completed'
		)
		WHERE (required_device_id IS NOT NULL AND confirmed_at IS NULL)
		   OR (state = 'pending' AND coordinator = ?2)
		ORDER BY requested_at, conversation_id`, accountID, deviceID)
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
	eventID, err := completeMLSRevocationIfConfirmed(ctx, tx, conversationID, revokedDeviceID, time.Now().UTC())
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
}
