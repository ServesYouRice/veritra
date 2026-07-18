package storage

import (
	"context"
	"database/sql"
	"errors"

	"private-messenger/server/internal/domain"
)

func (s *Store) ListAdminAccounts(ctx context.Context, limit int, afterID string) ([]domain.AdminAccount, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT a.id, a.username, a.role, a.status, a.created_at,
		       (SELECT COUNT(*) FROM devices d WHERE d.account_id = a.id AND d.revoked_at IS NULL),
		       (SELECT COUNT(*) FROM attachment_envelopes ae WHERE ae.owner_account_id = a.id),
		       (SELECT COUNT(*) FROM backup_blobs bb WHERE bb.account_id = a.id),
		       COALESCE((SELECT SUM(size_bytes) FROM attachment_envelopes ae WHERE ae.owner_account_id = a.id), 0)
		         + COALESCE((SELECT SUM(size_bytes) FROM backup_blobs bb WHERE bb.account_id = a.id), 0)
		FROM accounts a
		WHERE a.deleted_at IS NULL AND (? = '' OR a.id > ?)
		ORDER BY a.id LIMIT ?`, afterID, afterID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	accounts := make([]domain.AdminAccount, 0)
	for rows.Next() {
		var account domain.AdminAccount
		var created string
		if err := rows.Scan(&account.ID, &account.Username, &account.Role, &account.Status, &created, &account.DeviceCount, &account.AttachmentCount, &account.BackupCount, &account.StorageBytes); err != nil {
			return nil, err
		}
		account.CreatedAt = parseTime(created)
		accounts = append(accounts, account)
	}
	return accounts, rows.Err()
}

func (s *Store) SetAccountStatus(ctx context.Context, actorAccountID, targetAccountID, status string) error {
	if status != "active" && status != "suspended" {
		return ErrInvalidInput
	}
	if actorAccountID == targetAccountID {
		return ErrForbidden
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var actorRole, targetRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM accounts WHERE id = ? AND status = 'active' AND deleted_at IS NULL`, actorAccountID).Scan(&actorRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrForbidden
		}
		return err
	}
	if err := tx.QueryRowContext(ctx, `SELECT role FROM accounts WHERE id = ? AND deleted_at IS NULL`, targetAccountID).Scan(&targetRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if !domain.CanManageInvites(actorRole) || domain.RoleRank(actorRole) <= domain.RoleRank(targetRole) {
		return ErrForbidden
	}
	if _, err := tx.ExecContext(ctx, `UPDATE accounts SET status = ? WHERE id = ?`, status, targetAccountID); err != nil {
		return err
	}
	if status == "suspended" {
		if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ?`, targetAccountID); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE push_subscriptions SET disabled_at = COALESCE(disabled_at, ?) WHERE account_id = ?`, nowString(), targetAccountID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) AdminRevokeInvite(ctx context.Context, inviteID string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE invites SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, nowString(), inviteID)
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) ListAdminAuditEvents(ctx context.Context, afterID int64, limit int) ([]domain.AdminAuditEvent, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, actor_account_id, event_type, metadata_json, created_at FROM audit_events WHERE id > ? ORDER BY id LIMIT ?`, afterID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := make([]domain.AdminAuditEvent, 0)
	for rows.Next() {
		var event domain.AdminAuditEvent
		var actor sql.NullString
		var metadata, created string
		if err := rows.Scan(&event.ID, &actor, &event.EventType, &metadata, &created); err != nil {
			return nil, err
		}
		if actor.Valid {
			event.ActorAccountID = &actor.String
		}
		event.Metadata = []byte(metadata)
		event.CreatedAt = parseTime(created)
		events = append(events, event)
	}
	return events, rows.Err()
}
