package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/domain"
)

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
	categories, err := s.exportAssociatedData(ctx, accountID)
	if err != nil {
		return domain.AccountExport{}, err
	}
	return domain.AccountExport{ManifestVersion: "v1", Account: account, Devices: devices, Conversations: conversations, Messages: messages, Categories: categories}, nil
}

func (s *Store) exportAssociatedData(ctx context.Context, accountID string) (map[string][]json.RawMessage, error) {
	queries := map[string]string{
		"memberships":        `SELECT json_object('community_id', community_id, 'conversation_id', conversation_id, 'role', role, 'created_at', created_at) FROM memberships WHERE account_id = ? ORDER BY created_at, id`,
		"invites":            `SELECT json_object('id', id, 'max_uses', max_uses, 'uses', uses, 'expires_at', expires_at, 'created_at', created_at, 'revoked_at', revoked_at) FROM invites WHERE created_by = ? ORDER BY created_at, id`,
		"attachments":        `SELECT json_object('id', id, 'conversation_id', conversation_id, 'ciphertext_sha256', ciphertext_sha256, 'size_bytes', size_bytes, 'crypto_metadata', json(crypto_metadata_json), 'created_at', created_at) FROM attachment_envelopes WHERE owner_account_id = ? ORDER BY created_at, id`,
		"reactions":          `SELECT json_object('id', id, 'message_id', message_id, 'ciphertext_hex', hex(reaction_ciphertext), 'created_at', created_at) FROM reactions WHERE account_id = ? ORDER BY created_at, id`,
		"read_receipts":      `SELECT json_object('conversation_id', conversation_id, 'message_id', message_id, 'read_at', read_at) FROM read_receipts WHERE account_id = ? ORDER BY read_at, conversation_id`,
		"push_subscriptions": `SELECT json_object('id', id, 'device_id', device_id, 'provider', provider, 'endpoint', endpoint, 'public_key', public_key, 'auth_secret', auth_secret, 'created_at', created_at, 'disabled_at', disabled_at) FROM push_subscriptions WHERE account_id = ? ORDER BY created_at, id`,
		"backups":            `SELECT json_object('id', id, 'device_id', device_id, 'ciphertext_sha256', ciphertext_sha256, 'size_bytes', size_bytes, 'key_derivation_metadata', json(key_derivation_metadata_json), 'created_at', created_at) FROM backup_blobs WHERE account_id = ? ORDER BY created_at, id`,
		"calls":              `SELECT json_object('id', id, 'conversation_id', conversation_id, 'state', state, 'metadata', json(metadata_json), 'created_at', created_at, 'ended_at', ended_at, 'expires_at', expires_at) FROM call_sessions WHERE created_by = ? ORDER BY created_at, id`,
		"audit_events":       `SELECT json_object('id', id, 'event_type', event_type, 'metadata', json(metadata_json), 'created_at', created_at) FROM audit_events WHERE actor_account_id = ? ORDER BY created_at, id`,
	}
	categories := make(map[string][]json.RawMessage, len(queries))
	for name, query := range queries {
		rows, err := s.db.QueryContext(ctx, query, accountID)
		if err != nil {
			return nil, err
		}
		items := make([]json.RawMessage, 0)
		for rows.Next() {
			var raw string
			if err := rows.Scan(&raw); err != nil {
				rows.Close()
				return nil, err
			}
			items = append(items, json.RawMessage(raw))
		}
		if err := rows.Close(); err != nil {
			return nil, err
		}
		categories[name] = items
	}
	return categories, nil
}

func (s *Store) DeleteAccount(ctx context.Context, accountID string) error {
	_, err := s.DeleteAccountData(ctx, accountID)
	return err
}

// DeleteAccountData scrubs account-controlled metadata while retaining only
// pseudonymous IDs required by shared ciphertext history and audit integrity.
// Returned storage keys must be deleted from the blob store after commit.
func (s *Store) DeleteAccountData(ctx context.Context, accountID string) ([]string, error) {
	now := nowString()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var role string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM accounts WHERE id = ? AND deleted_at IS NULL`, accountID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if role == domain.RoleOwner {
		var activeOwners int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE role = 'owner' AND deleted_at IS NULL`).Scan(&activeOwners); err != nil {
			return nil, err
		}
		if activeOwners <= 1 {
			return nil, ErrLastOwner
		}
	}
	blobRows, err := tx.QueryContext(ctx, `
		SELECT storage_key FROM attachment_envelopes WHERE owner_account_id = ?
		UNION ALL
		SELECT storage_key FROM backup_blobs WHERE account_id = ?`, accountID, accountID)
	if err != nil {
		return nil, err
	}
	var storageKeys []string
	for blobRows.Next() {
		var key string
		if err := blobRows.Scan(&key); err != nil {
			blobRows.Close()
			return nil, err
		}
		storageKeys = append(storageKeys, key)
	}
	if err := blobRows.Close(); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE invites SET revoked_at = COALESCE(revoked_at, ?) WHERE created_by = ?`, now, accountID); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sessions WHERE account_id = ?`, accountID); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE devices SET name = 'Deleted device', key_package = X'', signing_key = NULL, auth_secret_hash = NULL, revoked_at = COALESCE(revoked_at, ?) WHERE account_id = ?`, now, accountID); err != nil {
		return nil, err
	}
	for _, query := range []string{
		`DELETE FROM memberships WHERE account_id = ?`,
		`DELETE FROM reactions WHERE account_id = ?`,
		`DELETE FROM read_receipts WHERE account_id = ?`,
		`DELETE FROM push_subscriptions WHERE account_id = ?`,
		`DELETE FROM device_links WHERE account_id = ?`,
		`DELETE FROM attachment_envelopes WHERE owner_account_id = ?`,
		`DELETE FROM backup_blobs WHERE account_id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, query, accountID); err != nil {
			return nil, err
		}
	}
	result, err := tx.ExecContext(ctx, `UPDATE accounts SET username = 'deleted_' || replace(id, '_', ''), email = NULL, password_hash = '!', status = 'deleted', deleted_at = COALESCE(deleted_at, ?) WHERE id = ?`, now, accountID)
	if err != nil {
		return nil, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return nil, err
	}
	if rows == 0 {
		return nil, ErrNotFound
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return storageKeys, nil
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
