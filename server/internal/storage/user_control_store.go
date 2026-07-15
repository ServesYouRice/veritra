package storage

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
)

func (s *Store) BlockAccount(ctx context.Context, blockerAccountID, blockedAccountID string) (domain.AccountBlock, error) {
	if blockerAccountID == blockedAccountID || !domain.ValidID("acct", blockedAccountID) {
		return domain.AccountBlock{}, ErrInvalidInput
	}
	var active int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, blockedAccountID).Scan(&active); err != nil {
		return domain.AccountBlock{}, err
	}
	if active == 0 {
		return domain.AccountBlock{}, ErrNotFound
	}
	createdAt := time.Now().UTC()
	_, err := s.db.ExecContext(ctx, `INSERT INTO account_blocks(blocker_account_id, blocked_account_id, created_at) VALUES(?, ?, ?) ON CONFLICT(blocker_account_id, blocked_account_id) DO NOTHING`, blockerAccountID, blockedAccountID, formatTime(createdAt))
	if err != nil {
		return domain.AccountBlock{}, err
	}
	return domain.AccountBlock{AccountID: blockedAccountID, CreatedAt: createdAt}, nil
}

func (s *Store) UnblockAccount(ctx context.Context, blockerAccountID, blockedAccountID string) error {
	result, err := s.db.ExecContext(ctx, `DELETE FROM account_blocks WHERE blocker_account_id = ? AND blocked_account_id = ?`, blockerAccountID, blockedAccountID)
	if err != nil {
		return err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) ListBlockedAccounts(ctx context.Context, blockerAccountID string) ([]domain.AccountBlock, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT b.blocked_account_id, a.username, b.created_at FROM account_blocks b JOIN accounts a ON a.id = b.blocked_account_id WHERE b.blocker_account_id = ? ORDER BY b.created_at DESC, b.blocked_account_id`, blockerAccountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	blocks := make([]domain.AccountBlock, 0)
	for rows.Next() {
		var block domain.AccountBlock
		var created string
		if err := rows.Scan(&block.AccountID, &block.Username, &created); err != nil {
			return nil, err
		}
		block.CreatedAt = parseTime(created)
		blocks = append(blocks, block)
	}
	return blocks, rows.Err()
}

func (s *Store) ConversationNotificationsMuted(ctx context.Context, conversationID, accountID string) (bool, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil || !member {
		if err != nil {
			return false, err
		}
		return false, ErrNotMember
	}
	var muted bool
	err = s.db.QueryRowContext(ctx, `SELECT muted FROM conversation_notification_preferences WHERE account_id = ? AND conversation_id = ?`, accountID, conversationID).Scan(&muted)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return muted, err
}

func (s *Store) SetConversationNotificationsMuted(ctx context.Context, conversationID, accountID string, muted bool) error {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return err
	}
	if !member {
		return ErrNotMember
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO conversation_notification_preferences(account_id, conversation_id, muted, updated_at) VALUES(?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO UPDATE SET muted = excluded.muted, updated_at = excluded.updated_at`, accountID, conversationID, muted, nowString())
	return err
}

// ConversationRecipientsForSender omits accounts that have blocked the sender.
func (s *Store) ConversationRecipientsForSender(ctx context.Context, conversationID, senderAccountID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT m.account_id FROM memberships m WHERE m.conversation_id = ? AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = m.account_id AND b.blocked_account_id = ?) ORDER BY m.account_id`, conversationID, senderAccountID)
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
