package storage

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/domain"
)

func (s *Store) SaveMessageEnvelope(ctx context.Context, envelope domain.MessageEnvelope) (domain.MessageEnvelope, bool, error) {
	saved, duplicate, _, err := s.saveMessageEnvelope(ctx, envelope, false)
	return saved, duplicate, err
}

func (s *Store) SaveMessageEnvelopeWithSyncEvent(ctx context.Context, envelope domain.MessageEnvelope) (domain.MessageEnvelope, bool, int64, error) {
	return s.saveMessageEnvelope(ctx, envelope, true)
}

func (s *Store) saveMessageEnvelope(ctx context.Context, envelope domain.MessageEnvelope, withSyncEvent bool) (domain.MessageEnvelope, bool, int64, error) {
	if len(envelope.CryptoMetadata) == 0 {
		envelope.CryptoMetadata = json.RawMessage(`{}`)
	}
	if len(envelope.AttachmentRefs) == 0 {
		envelope.AttachmentRefs = json.RawMessage(`[]`)
	}
	attachmentIDs, err := parseAttachmentIDs(envelope.AttachmentRefs)
	if err != nil {
		return domain.MessageEnvelope{}, false, 0, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.MessageEnvelope{}, false, 0, err
	}
	defer tx.Rollback()
	for _, attachmentID := range attachmentIDs {
		var count int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM attachment_envelopes WHERE id = ? AND owner_account_id = ? AND conversation_id = ?`, attachmentID, envelope.SenderAccountID, envelope.ConversationID).Scan(&count); err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
		if count == 0 {
			return domain.MessageEnvelope{}, false, 0, ErrInvalidInput
		}
	}
	now := time.Now().UTC()
	if _, err := tx.ExecContext(ctx, `DELETE FROM message_envelopes WHERE sender_device_id = ? AND idempotency_key = ? AND expires_at IS NOT NULL AND expires_at <= ?`, envelope.SenderDeviceID, envelope.IdempotencyKey, formatTime(now)); err != nil {
		return domain.MessageEnvelope{}, false, 0, err
	}
	existing, err := scanMessage(tx.QueryRowContext(ctx, `SELECT id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at FROM message_envelopes WHERE sender_device_id = ? AND idempotency_key = ?`, envelope.SenderDeviceID, envelope.IdempotencyKey))
	if err == nil {
		if !sameIdempotentMessage(existing, envelope) {
			return domain.MessageEnvelope{}, false, 0, ErrIdempotencyConflict
		}
		if err := tx.Commit(); err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
		return existing, true, 0, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return domain.MessageEnvelope{}, false, 0, err
	}
	var memberCount int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, envelope.ConversationID, envelope.SenderAccountID).Scan(&memberCount); err != nil {
		return domain.MessageEnvelope{}, false, 0, err
	}
	if memberCount == 0 {
		return domain.MessageEnvelope{}, false, 0, ErrNotMember
	}
	for _, referenceID := range []*string{envelope.ReplyToID, envelope.ThreadRootID} {
		if referenceID == nil || strings.TrimSpace(*referenceID) == "" {
			continue
		}
		var referenceConversation string
		if err := tx.QueryRowContext(ctx, `SELECT conversation_id FROM message_envelopes WHERE id = ? AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)`, *referenceID, formatTime(now)).Scan(&referenceConversation); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return domain.MessageEnvelope{}, false, 0, ErrInvalidInput
			}
			return domain.MessageEnvelope{}, false, 0, err
		}
		if referenceConversation != envelope.ConversationID {
			return domain.MessageEnvelope{}, false, 0, ErrInvalidInput
		}
	}
	if envelope.ID == "" {
		envelope.ID, err = domain.NewID("msg")
		if err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
	}
	envelope.CreatedAt = now
	var retention sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT retention_seconds FROM conversations WHERE id = ?`, envelope.ConversationID).Scan(&retention); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.MessageEnvelope{}, false, 0, ErrNotFound
		}
		return domain.MessageEnvelope{}, false, 0, err
	}
	if retention.Valid {
		retentionExpiresAt := envelope.CreatedAt.Add(time.Duration(retention.Int64) * time.Second)
		if envelope.ExpiresAt == nil || envelope.ExpiresAt.After(retentionExpiresAt) {
			envelope.ExpiresAt = &retentionExpiresAt
		}
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		envelope.ID, envelope.ConversationID, envelope.SenderAccountID, envelope.SenderDeviceID, envelope.IdempotencyKey, envelope.Ciphertext, envelope.CryptoProtocol, string(envelope.CryptoMetadata), string(envelope.AttachmentRefs), nullableString(envelope.ReplyToID), nullableString(envelope.ThreadRootID), formatTime(envelope.CreatedAt), nullableTime(envelope.ExpiresAt))
	if err != nil {
		return domain.MessageEnvelope{}, false, 0, err
	}
	for _, attachmentID := range attachmentIDs {
		if _, err := tx.ExecContext(ctx, `INSERT INTO message_attachments(message_id, attachment_id) VALUES(?, ?)`, envelope.ID, attachmentID); err != nil {
			return domain.MessageEnvelope{}, false, 0, ErrInvalidInput
		}
	}
	var eventID int64
	if withSyncEvent {
		payload, err := json.Marshal(map[string]string{"message_id": envelope.ID, "conversation_id": envelope.ConversationID})
		if err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
		result, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('message.envelope.created', NULL, ?, ?, ?)`, envelope.ConversationID, string(payload), formatTime(now))
		if err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
		eventID, err = result.LastInsertId()
		if err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.MessageEnvelope{}, false, 0, err
	}
	return envelope, false, eventID, nil
}

func parseAttachmentIDs(raw json.RawMessage) ([]string, error) {
	var refs []interface{}
	if err := json.Unmarshal(raw, &refs); err != nil || len(refs) > 20 {
		return nil, ErrInvalidInput
	}
	ids := make([]string, 0, len(refs))
	seen := make(map[string]struct{}, len(refs))
	for _, ref := range refs {
		var id string
		switch value := ref.(type) {
		case string:
			id = value
		case map[string]interface{}:
			id, _ = value["id"].(string)
		}
		id = strings.TrimSpace(id)
		if id == "" {
			return nil, ErrInvalidInput
		}
		if _, exists := seen[id]; exists {
			return nil, ErrInvalidInput
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	return ids, nil
}

func sameIdempotentMessage(existing, requested domain.MessageEnvelope) bool {
	return existing.ConversationID == requested.ConversationID &&
		existing.SenderAccountID == requested.SenderAccountID &&
		existing.SenderDeviceID == requested.SenderDeviceID &&
		existing.CryptoProtocol == requested.CryptoProtocol &&
		bytes.Equal(existing.Ciphertext, requested.Ciphertext) &&
		bytes.Equal(existing.CryptoMetadata, requested.CryptoMetadata) &&
		bytes.Equal(existing.AttachmentRefs, requested.AttachmentRefs) &&
		equalOptionalString(existing.ReplyToID, requested.ReplyToID) &&
		equalOptionalString(existing.ThreadRootID, requested.ThreadRootID)
}

func equalOptionalString(left, right *string) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

func (s *Store) messageByIdempotency(ctx context.Context, deviceID, key string) (domain.MessageEnvelope, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at FROM message_envelopes WHERE sender_device_id = ? AND idempotency_key = ? AND (expires_at IS NULL OR expires_at > ?)`, deviceID, key, nowString())
	msg, err := scanMessage(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.MessageEnvelope{}, ErrNotFound
		}
		return domain.MessageEnvelope{}, err
	}
	return msg, nil
}

func (s *Store) MessageByID(ctx context.Context, messageID string) (domain.MessageEnvelope, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at FROM message_envelopes WHERE id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, nowString())
	msg, err := scanMessage(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.MessageEnvelope{}, ErrNotFound
		}
		return domain.MessageEnvelope{}, err
	}
	return msg, nil
}

func (s *Store) UpdateMessageEnvelope(ctx context.Context, messageID, accountID string, ciphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, error) {
	if len(ciphertext) == 0 || strings.TrimSpace(cryptoProtocol) == "" {
		return domain.MessageEnvelope{}, ErrForbidden
	}
	if len(cryptoMetadata) == 0 {
		cryptoMetadata = json.RawMessage(`{}`)
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE message_envelopes
		SET ciphertext = ?, crypto_protocol = ?, crypto_metadata_json = ?, edited_at = ?
		WHERE id = ? AND sender_account_id = ? AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)`,
		ciphertext, cryptoProtocol, string(cryptoMetadata), nowString(), messageID, accountID, nowString())
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	return s.messageAfterOwnedMutation(ctx, messageID, result)
}

func (s *Store) DeleteMessageEnvelope(ctx context.Context, messageID, accountID string, markerCiphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, error) {
	if len(markerCiphertext) == 0 || strings.TrimSpace(cryptoProtocol) == "" {
		return domain.MessageEnvelope{}, ErrForbidden
	}
	if len(cryptoMetadata) == 0 {
		cryptoMetadata = json.RawMessage(`{"deleted":true}`)
	}
	now := nowString()
	result, err := s.db.ExecContext(ctx, `
		UPDATE message_envelopes
		SET ciphertext = ?, crypto_protocol = ?, crypto_metadata_json = ?, deleted_at = ?
		WHERE id = ? AND sender_account_id = ? AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)`,
		markerCiphertext, cryptoProtocol, string(cryptoMetadata), now, messageID, accountID, nowString())
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	return s.messageAfterOwnedMutation(ctx, messageID, result)
}

func (s *Store) messageAfterOwnedMutation(ctx context.Context, messageID string, result sql.Result) (domain.MessageEnvelope, error) {
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	if rows == 0 {
		if _, err := s.MessageByID(ctx, messageID); errors.Is(err, ErrNotFound) {
			return domain.MessageEnvelope{}, ErrNotFound
		} else if err != nil {
			return domain.MessageEnvelope{}, err
		}
		return domain.MessageEnvelope{}, ErrForbidden
	}
	return s.MessageByID(ctx, messageID)
}

// ListMessagesOptions controls pagination for ListMessages. Only one of
// BeforeID/AfterID may be set; both empty returns the most recent page.
type ListMessagesOptions struct {
	Limit    int
	BeforeID string // returns messages strictly older than this message id
	AfterID  string // returns messages strictly newer than this message id
}

func (s *Store) ListMessages(ctx context.Context, conversationID, accountID string, opts ListMessagesOptions) ([]domain.MessageEnvelope, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	limit := opts.Limit
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	if opts.BeforeID != "" && opts.AfterID != "" {
		return nil, fmt.Errorf("before_id and after_id are mutually exclusive")
	}
	const cols = `id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at`
	var (
		rows *sql.Rows
	)
	switch {
	case opts.BeforeID != "":
		cursorAt, err := s.messageCursor(ctx, conversationID, opts.BeforeID)
		if err != nil {
			return nil, err
		}
		rows, err = s.db.QueryContext(ctx, `SELECT `+cols+` FROM message_envelopes
			WHERE conversation_id = ? AND (expires_at IS NULL OR expires_at > ?) AND (created_at < ? OR (created_at = ? AND id < ?))
			ORDER BY created_at DESC, id DESC LIMIT ?`,
			conversationID, nowString(), cursorAt, cursorAt, opts.BeforeID, limit)
		if err != nil {
			return nil, err
		}
	case opts.AfterID != "":
		cursorAt, err := s.messageCursor(ctx, conversationID, opts.AfterID)
		if err != nil {
			return nil, err
		}
		rows, err = s.db.QueryContext(ctx, `SELECT `+cols+` FROM message_envelopes
			WHERE conversation_id = ? AND (expires_at IS NULL OR expires_at > ?) AND (created_at > ? OR (created_at = ? AND id > ?))
			ORDER BY created_at ASC, id ASC LIMIT ?`,
			conversationID, nowString(), cursorAt, cursorAt, opts.AfterID, limit)
		if err != nil {
			return nil, err
		}
	default:
		rows, err = s.db.QueryContext(ctx, `SELECT `+cols+` FROM message_envelopes
			WHERE conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)
			ORDER BY created_at DESC, id DESC LIMIT ?`, conversationID, nowString(), limit)
		if err != nil {
			return nil, err
		}
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

// messageCursor returns the created_at of a message in a conversation, or
// ErrNotFound if the message does not exist or belongs to a different
// conversation. Used to validate before/after cursors.
func (s *Store) messageCursor(ctx context.Context, conversationID, messageID string) (string, error) {
	var createdAt string
	err := s.db.QueryRowContext(ctx, `SELECT created_at FROM message_envelopes WHERE id = ? AND conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, conversationID, nowString()).Scan(&createdAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	return createdAt, nil
}

func (s *Store) conversationRetention(ctx context.Context, conversationID string) (*int64, error) {
	var retention sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT retention_seconds FROM conversations WHERE id = ?`, conversationID).Scan(&retention); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if !retention.Valid {
		return nil, nil
	}
	return &retention.Int64, nil
}

func (s *Store) pruneExpiredMessageByIdempotency(ctx context.Context, deviceID, key string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM message_envelopes WHERE sender_device_id = ? AND idempotency_key = ? AND expires_at IS NOT NULL AND expires_at <= ?`, deviceID, key, formatTime(now.UTC()))
	return err
}

// PruneExpiredMessages deletes server-held encrypted envelopes whose
// disappearing-message expiry has passed.
func (s *Store) PruneExpiredMessages(ctx context.Context, now time.Time) (int64, error) {
	removed, _, err := s.PruneExpiredContent(ctx, now)
	return removed, err
}

// PruneExpiredContent removes a bounded page of expired messages and their
// linked encrypted attachments. It also reaps uploads that were never linked
// to a message after a 24-hour grace period. Returned storage keys must be
// deleted from the blob store after the database transaction commits.
func (s *Store) PruneExpiredContent(ctx context.Context, now time.Time) (int64, []string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, nil, err
	}
	defer tx.Rollback()
	cutoff := formatTime(now.UTC())
	rows, err := tx.QueryContext(ctx, `
		SELECT DISTINCT a.storage_key
		FROM attachment_envelopes a
		JOIN message_attachments ma ON ma.attachment_id = a.id
		WHERE ma.message_id IN (
			SELECT id FROM message_envelopes
			WHERE expires_at IS NOT NULL AND expires_at <= ?
			ORDER BY expires_at, id LIMIT 500
		)`, cutoff)
	if err != nil {
		return 0, nil, err
	}
	storageKeys := make([]string, 0)
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			rows.Close()
			return 0, nil, err
		}
		storageKeys = append(storageKeys, key)
	}
	if err := rows.Close(); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM attachment_envelopes WHERE id IN (
			SELECT ma.attachment_id FROM message_attachments ma
			JOIN message_envelopes me ON me.id = ma.message_id
			WHERE me.expires_at IS NOT NULL AND me.expires_at <= ?
			ORDER BY me.expires_at, me.id LIMIT 500
		)`, cutoff); err != nil {
		return 0, nil, err
	}
	result, err := tx.ExecContext(ctx, `
		DELETE FROM message_envelopes
		WHERE id IN (
			SELECT id FROM message_envelopes
			WHERE expires_at IS NOT NULL AND expires_at <= ?
			ORDER BY expires_at, id
			LIMIT 500
		)`, cutoff)
	if err != nil {
		return 0, nil, err
	}
	removed, err := result.RowsAffected()
	if err != nil {
		return 0, nil, err
	}
	orphanCutoff := formatTime(now.UTC().Add(-24 * time.Hour))
	orphans, err := tx.QueryContext(ctx, `SELECT storage_key FROM attachment_envelopes WHERE created_at < ? AND NOT EXISTS (SELECT 1 FROM message_attachments ma WHERE ma.attachment_id = attachment_envelopes.id) ORDER BY created_at, id LIMIT 500`, orphanCutoff)
	if err != nil {
		return 0, nil, err
	}
	orphanKeys := make([]string, 0)
	for orphans.Next() {
		var key string
		if err := orphans.Scan(&key); err != nil {
			orphans.Close()
			return 0, nil, err
		}
		orphanKeys = append(orphanKeys, key)
	}
	if err := orphans.Close(); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM attachment_envelopes WHERE id IN (SELECT a.id FROM attachment_envelopes a WHERE a.created_at < ? AND NOT EXISTS (SELECT 1 FROM message_attachments ma WHERE ma.attachment_id = a.id) ORDER BY a.created_at, a.id LIMIT 500)`, orphanCutoff); err != nil {
		return 0, nil, err
	}
	storageKeys = append(storageKeys, orphanKeys...)
	if err := tx.Commit(); err != nil {
		return 0, nil, err
	}
	return removed, storageKeys, nil
}

// PruneSyncEvents deletes sync events older than the cutoff. Returns the
// number of rows removed. Intended to be run periodically by a background
// sweeper so the table doesn't grow unbounded.
func (s *Store) PruneSyncEvents(ctx context.Context, olderThan time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM sync_events WHERE created_at < ?`, formatTime(olderThan.UTC()))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// PruneAuditEvents deletes audit events older than the cutoff.
func (s *Store) PruneAuditEvents(ctx context.Context, olderThan time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM audit_events WHERE created_at < ?`, formatTime(olderThan.UTC()))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// RecordAuditEvent appends a metadata-only audit row. Callers MUST NOT pass
// message content, ciphertext, or any field that would defeat the privacy
// promise that admins cannot read user data.
func (s *Store) RecordAuditEvent(ctx context.Context, actorAccountID *string, eventType string, metadata interface{}) error {
	payload := json.RawMessage(`{}`)
	if metadata != nil {
		b, err := json.Marshal(metadata)
		if err != nil {
			return err
		}
		payload = b
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO audit_events(actor_account_id, event_type, metadata_json, created_at) VALUES(?, ?, ?, ?)`, nullableString(actorAccountID), eventType, string(payload), nowString())
	return err
}

func (s *Store) SaveSyncEvent(ctx context.Context, eventType string, accountID *string, conversationID string, payload interface{}) (int64, error) {
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	result, err := s.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES(?, ?, ?, ?, ?)`, eventType, nullableString(accountID), nullableEmptyString(conversationID), string(payloadBytes), nowString())
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

func (s *Store) ListSyncEvents(ctx context.Context, accountID string, afterID int64, limit int) ([]domain.SyncEvent, error) {
	_, oldest, _, err := s.SyncBounds(ctx, accountID)
	if err != nil {
		return nil, err
	}
	if afterID > 0 && oldest > 0 && afterID < oldest-1 {
		return nil, ErrSyncCursorExpired
	}
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, event_type, account_id, conversation_id, payload_json, created_at
		FROM (
			SELECT id, event_type, account_id, conversation_id, payload_json, created_at
			FROM sync_events
			WHERE id > ? AND account_id = ?
			UNION ALL
			SELECT se.id, se.event_type, se.account_id, se.conversation_id, se.payload_json, se.created_at
			FROM sync_events se
			JOIN memberships m ON m.conversation_id = se.conversation_id
			WHERE se.id > ? AND se.account_id IS NULL AND m.account_id = ?
		) visible_events
		ORDER BY id ASC
		LIMIT ?`, afterID, accountID, afterID, accountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []domain.SyncEvent
	for rows.Next() {
		event, err := scanSyncEvent(rows)
		if err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

func (s *Store) SyncBounds(ctx context.Context, accountID string) (string, int64, int64, error) {
	var epoch string
	if err := s.db.QueryRowContext(ctx, `SELECT epoch FROM sync_state WHERE id = 1`).Scan(&epoch); err != nil {
		return "", 0, 0, err
	}
	var oldest, latest sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
		SELECT MIN(id), MAX(id) FROM (
			SELECT id FROM sync_events WHERE account_id = ?
			UNION ALL
			SELECT se.id FROM sync_events se JOIN memberships m ON m.conversation_id = se.conversation_id WHERE se.account_id IS NULL AND m.account_id = ?
		)`, accountID, accountID).Scan(&oldest, &latest)
	if err != nil {
		return "", 0, 0, err
	}
	return epoch, oldest.Int64, latest.Int64, nil
}

func (s *Store) SearchMetadata(ctx context.Context, accountID, query string, limit, offset int) ([]domain.MetadataSearchResult, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return []domain.MetadataSearchResult{}, nil
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	exact := query
	exactAccountID := ""
	if domain.ValidID("acct", query) {
		exactAccountID = query
	}
	prefixPattern := escapeLike(query) + "%"
	rows, err := s.db.QueryContext(ctx, `
		SELECT type, id, label
		FROM (
			-- Accounts are matched on the exact (case-insensitive) username only.
			-- Prefix/contains matching here would let any authenticated user walk
			-- the substring space and enumerate the entire user directory, which
			-- is a metadata leak for a private messenger. Communities/channels
			-- below stay prefix/contains because they are scoped to the caller's
			-- memberships. Prefix-only matching also keeps this endpoint on
			-- ordinary indexes instead of leading-wildcard scans.
			SELECT 'account' AS type, id, username AS label, 0 AS rank
			FROM accounts
			WHERE deleted_at IS NULL AND (username = ? COLLATE NOCASE OR id = ?)
			UNION ALL
			SELECT 'community' AS type, c.id, c.name AS label,
				CASE
					WHEN c.name = ? COLLATE NOCASE THEN 0
					ELSE 1
				END AS rank
			FROM communities c
			JOIN memberships m ON m.community_id = c.id
			WHERE m.account_id = ? AND c.name LIKE ? ESCAPE '\'
			UNION ALL
			SELECT 'channel' AS type, ch.id, ch.name AS label,
				CASE
					WHEN ch.name = ? COLLATE NOCASE THEN 0
					ELSE 1
				END AS rank
			FROM channels ch
			JOIN memberships m ON m.community_id = ch.community_id
			WHERE m.account_id = ? AND ch.name LIKE ? ESCAPE '\'
		)
		ORDER BY rank, label COLLATE NOCASE, type, id
		LIMIT ? OFFSET ?`,
		exact, exactAccountID,
		exact, accountID, prefixPattern,
		exact, accountID, prefixPattern,
		limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results := make([]domain.MetadataSearchResult, 0, limit)
	for rows.Next() {
		var result domain.MetadataSearchResult
		if err := rows.Scan(&result.Type, &result.ID, &result.Label); err != nil {
			return nil, err
		}
		results = append(results, result)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return results, nil
}
