package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/domain"
)

func (s *Store) CreateAttachmentEnvelope(ctx context.Context, attachment domain.AttachmentEnvelope) (domain.AttachmentEnvelope, error) {
	if attachment.ConversationID != nil {
		member, err := s.IsConversationMember(ctx, *attachment.ConversationID, attachment.OwnerAccountID)
		if err != nil {
			return domain.AttachmentEnvelope{}, err
		}
		if !member {
			return domain.AttachmentEnvelope{}, ErrNotMember
		}
	}
	if attachment.ID == "" {
		id, err := domain.NewID("att")
		if err != nil {
			return domain.AttachmentEnvelope{}, err
		}
		attachment.ID = id
	}
	if len(attachment.CryptoMetadata) == 0 {
		attachment.CryptoMetadata = json.RawMessage(`{}`)
	}
	attachment.CreatedAt = time.Now().UTC()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	defer tx.Rollback()
	if err := enforceBlobQuota(ctx, tx, attachment.OwnerAccountID, attachment.SizeBytes); err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO attachment_envelopes(id, owner_account_id, conversation_id, storage_key, ciphertext_sha256, size_bytes, crypto_metadata_json, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, attachment.ID, attachment.OwnerAccountID, nullableString(attachment.ConversationID), attachment.StorageKey, attachment.CiphertextSHA256, attachment.SizeBytes, string(attachment.CryptoMetadata), formatTime(attachment.CreatedAt)); err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	return attachment, tx.Commit()
}

func (s *Store) ListAttachments(ctx context.Context, accountID string, limit int) ([]domain.AttachmentEnvelope, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT a.id, a.owner_account_id, a.conversation_id, a.storage_key, a.ciphertext_sha256, a.size_bytes, a.crypto_metadata_json, a.created_at
		FROM attachment_envelopes a
		LEFT JOIN memberships m ON m.conversation_id = a.conversation_id AND m.account_id = ?
		WHERE a.owner_account_id = ? OR m.id IS NOT NULL
		ORDER BY a.created_at DESC, a.id DESC LIMIT ?`, accountID, accountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]domain.AttachmentEnvelope, 0)
	for rows.Next() {
		attachment, err := scanAttachment(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, attachment)
	}
	return result, rows.Err()
}

func (s *Store) AttachmentForAccount(ctx context.Context, id, accountID string) (domain.AttachmentEnvelope, error) {
	attachment, err := scanAttachment(s.db.QueryRowContext(ctx, `
		SELECT a.id, a.owner_account_id, a.conversation_id, a.storage_key, a.ciphertext_sha256, a.size_bytes, a.crypto_metadata_json, a.created_at
		FROM attachment_envelopes a
		LEFT JOIN memberships m ON m.conversation_id = a.conversation_id AND m.account_id = ?
		WHERE a.id = ? AND (a.owner_account_id = ? OR m.id IS NOT NULL)`, accountID, id, accountID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.AttachmentEnvelope{}, ErrNotFound
	}
	return attachment, err
}

func (s *Store) DeleteAttachment(ctx context.Context, id, accountID string) (domain.AttachmentEnvelope, error) {
	attachment, err := s.AttachmentForAccount(ctx, id, accountID)
	if err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	if attachment.OwnerAccountID != accountID {
		return domain.AttachmentEnvelope{}, ErrForbidden
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM attachment_envelopes WHERE id = ? AND owner_account_id = ?`, id, accountID)
	if err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return domain.AttachmentEnvelope{}, ErrNotFound
	}
	return attachment, nil
}

func (s *Store) CreateReaction(ctx context.Context, messageID, accountID string, reactionCiphertext []byte) error {
	msg, err := s.MessageByID(ctx, messageID)
	if err != nil {
		return err
	}
	member, err := s.IsConversationMember(ctx, msg.ConversationID, accountID)
	if err != nil {
		return err
	}
	if !member {
		return ErrNotMember
	}
	id, err := domain.NewID("react")
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO reactions(id, message_id, account_id, reaction_ciphertext, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(message_id, account_id) DO UPDATE SET reaction_ciphertext = excluded.reaction_ciphertext, created_at = excluded.created_at`, id, messageID, accountID, reactionCiphertext, nowString())
	return err
}

func (s *Store) ListReactions(ctx context.Context, messageID, accountID string) ([]domain.Reaction, error) {
	message, err := s.MessageByID(ctx, messageID)
	if err != nil {
		return nil, err
	}
	member, err := s.IsConversationMember(ctx, message.ConversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, message_id, account_id, reaction_ciphertext, created_at FROM reactions WHERE message_id = ? ORDER BY created_at, id`, messageID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	reactions := make([]domain.Reaction, 0)
	for rows.Next() {
		var reaction domain.Reaction
		var created string
		if err := rows.Scan(&reaction.ID, &reaction.MessageID, &reaction.AccountID, &reaction.ReactionCiphertext, &created); err != nil {
			return nil, err
		}
		reaction.CreatedAt = parseTime(created)
		reactions = append(reactions, reaction)
	}
	return reactions, rows.Err()
}

func (s *Store) DeleteReaction(ctx context.Context, messageID, accountID string) (string, error) {
	message, err := s.MessageByID(ctx, messageID)
	if err != nil {
		return "", err
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM reactions WHERE message_id = ? AND account_id = ?`, messageID, accountID)
	if err != nil {
		return "", err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return "", ErrNotFound
	}
	return message.ConversationID, nil
}

func (s *Store) MarkRead(ctx context.Context, conversationID, accountID, messageID string) error {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return err
	}
	if !member {
		return ErrNotMember
	}
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM message_envelopes WHERE id = ? AND conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, conversationID, nowString()).Scan(&count); err != nil {
		return err
	}
	if count == 0 {
		return ErrNotFound
	}
	// Guard against rewinding the read cursor: only advance to a message
	// whose created_at is at or after the currently-recorded one.
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO read_receipts(account_id, conversation_id, message_id, read_at)
		VALUES(?, ?, ?, ?)
		ON CONFLICT(account_id, conversation_id) DO UPDATE SET
			message_id = excluded.message_id,
			read_at = excluded.read_at
		WHERE excluded.message_id != read_receipts.message_id
		  AND (SELECT created_at FROM message_envelopes WHERE id = excluded.message_id) >=
		      (SELECT created_at FROM message_envelopes WHERE id = read_receipts.message_id)`,
		accountID, conversationID, messageID, nowString())
	return err
}

type PushTarget struct {
	ID         string
	Endpoint   string
	PublicKey  string
	AuthSecret string
}

func (s *Store) CreatePushSubscription(ctx context.Context, accountID, deviceID, provider, endpoint, publicKey, authSecret string) (string, error) {
	id, err := domain.NewID("push")
	if err != nil {
		return "", err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var activeID string
	err = tx.QueryRowContext(ctx, `SELECT id FROM push_subscriptions WHERE account_id = ? AND device_id = ? AND provider = ? AND disabled_at IS NULL ORDER BY created_at DESC LIMIT 1`, accountID, deviceID, provider).Scan(&activeID)
	if errors.Is(err, sql.ErrNoRows) {
		if _, err := tx.ExecContext(ctx, `INSERT INTO push_subscriptions(id, account_id, device_id, provider, endpoint, public_key, auth_secret, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, id, accountID, nullableEmptyString(deviceID), provider, endpoint, publicKey, authSecret, nowString()); err != nil {
			return "", err
		}
		activeID = id
	} else if err != nil {
		return "", err
	} else if _, err := tx.ExecContext(ctx, `UPDATE push_subscriptions SET endpoint = ?, public_key = ?, auth_secret = ?, created_at = ? WHERE id = ?`, endpoint, publicKey, authSecret, nowString(), activeID); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return activeID, nil
}

func (s *Store) PushTargetsForConversation(ctx context.Context, conversationID, excludeAccountID string) ([]PushTarget, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT ps.id, ps.endpoint, COALESCE(ps.public_key, ''), COALESCE(ps.auth_secret, '')
		FROM push_subscriptions ps
		JOIN memberships m ON m.account_id = ps.account_id
		WHERE m.conversation_id = ? AND ps.account_id <> ? AND ps.provider = 'webpush' AND ps.disabled_at IS NULL
		ORDER BY ps.id
		LIMIT 500`, conversationID, excludeAccountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var targets []PushTarget
	for rows.Next() {
		var target PushTarget
		if err := rows.Scan(&target.ID, &target.Endpoint, &target.PublicKey, &target.AuthSecret); err != nil {
			return nil, err
		}
		targets = append(targets, target)
	}
	return targets, rows.Err()
}

func (s *Store) DisablePushTarget(ctx context.Context, subscriptionID string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE push_subscriptions SET disabled_at = COALESCE(disabled_at, ?) WHERE id = ?`, nowString(), subscriptionID)
	return err
}

// DisablePushSubscription marks the subscription disabled if it belongs to
// the caller's account. Returns ErrNotFound when no matching active row exists.
func (s *Store) DisablePushSubscription(ctx context.Context, subscriptionID, accountID string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE push_subscriptions SET disabled_at = ? WHERE id = ? AND account_id = ? AND disabled_at IS NULL`, nowString(), subscriptionID, accountID)
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

func (s *Store) CreateCallSession(ctx context.Context, conversationID, accountID string, metadata json.RawMessage) (domain.CallSession, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return domain.CallSession{}, err
	}
	if !member {
		return domain.CallSession{}, ErrNotMember
	}
	id, err := domain.NewID("call")
	if err != nil {
		return domain.CallSession{}, err
	}
	if len(metadata) == 0 {
		metadata = json.RawMessage(`{}`)
	}
	createdAt := time.Now().UTC()
	expiresAt := createdAt.Add(2 * time.Minute)
	_, err = s.db.ExecContext(ctx, `INSERT INTO call_sessions(id, conversation_id, created_by, state, metadata_json, created_at, expires_at) VALUES(?, ?, ?, 'ringing', ?, ?, ?)`, id, conversationID, accountID, string(metadata), formatTime(createdAt), formatTime(expiresAt))
	if err != nil {
		return domain.CallSession{}, err
	}
	return domain.CallSession{ID: id, ConversationID: conversationID, CreatedBy: accountID, State: "ringing", Metadata: metadata, CreatedAt: createdAt, ExpiresAt: &expiresAt}, nil
}

func (s *Store) ListCallSessions(ctx context.Context, conversationID, accountID string, limit int) ([]domain.CallSession, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, conversation_id, created_by, state, metadata_json, created_at, ended_at, expires_at FROM call_sessions WHERE conversation_id = ? ORDER BY created_at DESC, id DESC LIMIT ?`, conversationID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	calls := make([]domain.CallSession, 0)
	for rows.Next() {
		call, err := scanCall(rows)
		if err != nil {
			return nil, err
		}
		calls = append(calls, call)
	}
	return calls, rows.Err()
}

func (s *Store) TransitionCallSession(ctx context.Context, callID, accountID, nextState string, metadata json.RawMessage) (domain.CallSession, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.CallSession{}, err
	}
	defer tx.Rollback()
	call, err := scanCall(tx.QueryRowContext(ctx, `SELECT id, conversation_id, created_by, state, metadata_json, created_at, ended_at, expires_at FROM call_sessions WHERE id = ?`, callID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.CallSession{}, ErrNotFound
	}
	if err != nil {
		return domain.CallSession{}, err
	}
	var memberCount int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, call.ConversationID, accountID).Scan(&memberCount); err != nil {
		return domain.CallSession{}, err
	}
	if memberCount == 0 {
		return domain.CallSession{}, ErrNotMember
	}
	allowed := (call.State == "ringing" && (nextState == "active" || nextState == "rejected" || nextState == "missed" || nextState == "ended")) ||
		(call.State == "active" && nextState == "ended") || call.State == nextState
	if !allowed {
		return domain.CallSession{}, ErrInvalidInput
	}
	if len(metadata) > 0 {
		call.Metadata = metadata
	}
	now := time.Now().UTC()
	call.State = nextState
	terminal := nextState == "rejected" || nextState == "missed" || nextState == "ended"
	if terminal {
		call.EndedAt = &now
		expires := now.Add(7 * 24 * time.Hour)
		call.ExpiresAt = &expires
	} else if nextState == "active" {
		expires := now.Add(4 * time.Hour)
		call.ExpiresAt = &expires
	}
	if _, err := tx.ExecContext(ctx, `UPDATE call_sessions SET state = ?, metadata_json = ?, ended_at = ?, expires_at = ? WHERE id = ?`, call.State, string(call.Metadata), nullableTime(call.EndedAt), nullableTime(call.ExpiresAt), call.ID); err != nil {
		return domain.CallSession{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.CallSession{}, err
	}
	return call, nil
}

func (s *Store) PruneCallSessions(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM call_sessions WHERE id IN (SELECT id FROM call_sessions WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at, id LIMIT 500)`, formatTime(now.UTC()))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) PruneOperationalRows(ctx context.Context, now time.Time) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	cutoff := formatTime(now.UTC().Add(-30 * 24 * time.Hour))
	queries := []struct {
		query string
		arg   string
	}{
		{`DELETE FROM sessions WHERE token_hash IN (SELECT token_hash FROM sessions WHERE expires_at <= ? ORDER BY expires_at LIMIT 500)`, formatTime(now.UTC())},
		{`DELETE FROM invites WHERE id IN (SELECT id FROM invites WHERE (expires_at IS NOT NULL AND expires_at < ?) OR (revoked_at IS NOT NULL AND revoked_at < ?) ORDER BY COALESCE(revoked_at, expires_at), id LIMIT 500)`, cutoff},
		{`DELETE FROM device_links WHERE id IN (SELECT id FROM device_links WHERE expires_at < ? AND state IN ('consumed', 'revoked') ORDER BY expires_at, id LIMIT 500)`, cutoff},
		{`DELETE FROM push_subscriptions WHERE id IN (SELECT id FROM push_subscriptions WHERE disabled_at IS NOT NULL AND disabled_at < ? ORDER BY disabled_at, id LIMIT 500)`, cutoff},
	}
	var removed int64
	for i, item := range queries {
		var result sql.Result
		if i == 1 {
			result, err = tx.ExecContext(ctx, item.query, item.arg, item.arg)
		} else {
			result, err = tx.ExecContext(ctx, item.query, item.arg)
		}
		if err != nil {
			return 0, err
		}
		count, err := result.RowsAffected()
		if err != nil {
			return 0, err
		}
		removed += count
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return removed, nil
}

func (s *Store) CreateBackupBlob(ctx context.Context, accountID, deviceID, storageKey, ciphertextSHA256 string, sizeBytes int64, keyDerivationMetadata json.RawMessage) error {
	if len(keyDerivationMetadata) == 0 {
		keyDerivationMetadata = json.RawMessage(`{}`)
	}
	id, err := domain.NewID("backup")
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := enforceBlobQuota(ctx, tx, accountID, sizeBytes); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`, id, accountID, nullableEmptyString(deviceID), storageKey, ciphertextSHA256, sizeBytes, string(keyDerivationMetadata), nowString()); err != nil {
		return err
	}
	return tx.Commit()
}

func enforceBlobQuota(ctx context.Context, tx *sql.Tx, accountID string, incoming int64) error {
	const accountLimit int64 = 1 << 30
	const instanceLimit int64 = 10 << 30
	const usageQuery = `SELECT COALESCE(SUM(size_bytes), 0) FROM (
		SELECT owner_account_id AS account_id, size_bytes FROM attachment_envelopes
		UNION ALL SELECT account_id, size_bytes FROM backup_blobs
	)`
	var accountUsage, instanceUsage int64
	if err := tx.QueryRowContext(ctx, usageQuery+` WHERE account_id = ?`, accountID).Scan(&accountUsage); err != nil {
		return err
	}
	if err := tx.QueryRowContext(ctx, usageQuery).Scan(&instanceUsage); err != nil {
		return err
	}
	if incoming < 0 || accountUsage > accountLimit-incoming || instanceUsage > instanceLimit-incoming {
		return ErrStorageQuota
	}
	return nil
}

func (s *Store) ListBackups(ctx context.Context, accountID string, limit int) ([]domain.BackupBlob, error) {
	if limit <= 0 || limit > 100 {
		limit = 25
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at FROM backup_blobs WHERE account_id = ? ORDER BY created_at DESC, id DESC LIMIT ?`, accountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]domain.BackupBlob, 0)
	for rows.Next() {
		backup, err := scanBackup(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, backup)
	}
	return result, rows.Err()
}

func (s *Store) BackupForAccount(ctx context.Context, id, accountID string) (domain.BackupBlob, error) {
	backup, err := scanBackup(s.db.QueryRowContext(ctx, `SELECT id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at FROM backup_blobs WHERE id = ? AND account_id = ?`, id, accountID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.BackupBlob{}, ErrNotFound
	}
	return backup, err
}

func (s *Store) DeleteBackup(ctx context.Context, id, accountID string) (domain.BackupBlob, error) {
	backup, err := s.BackupForAccount(ctx, id, accountID)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM backup_blobs WHERE id = ? AND account_id = ?`, id, accountID)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return domain.BackupBlob{}, ErrNotFound
	}
	return backup, nil
}

// ExportAccountOptions controls pagination of the message portion of an
// account export. Account, devices, and conversations are always returned in
// full; only messages are paginated.
type ExportAccountOptions struct {
	Limit    int
	BeforeID string
}

// ExportAccount returns the caller's account, devices, conversations, and a
// page of messages ordered newest-first. When opts.Limit is hit, the caller
// must paginate using opts.BeforeID with the id of the oldest message in the
// returned page. This replaces the prior silent 1000-message cap.
