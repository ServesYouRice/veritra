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
	saved, duplicate, _, err := s.saveMessageEnvelope(ctx, envelope, false, nil)
	return saved, duplicate, err
}

func (s *Store) SaveMessageEnvelopeWithSyncEvent(ctx context.Context, envelope domain.MessageEnvelope) (domain.MessageEnvelope, bool, int64, error) {
	return s.saveMessageEnvelope(ctx, envelope, true, nil)
}

// SaveMessageEnvelopeWithSyncEventAndRecipients commits the message, sync event,
// and authorized conversation recipient snapshot through one transaction.
// The recipient snapshot is an ephemeral authorization result for realtime
// fanout; it is not persisted as message content or push work.
func (s *Store) SaveMessageEnvelopeWithSyncEventAndRecipients(ctx context.Context, envelope domain.MessageEnvelope) (domain.MessageEnvelope, bool, int64, []string, error) {
	var recipients []string
	saved, duplicate, eventID, err := s.saveMessageEnvelope(ctx, envelope, true, &recipients)
	return saved, duplicate, eventID, recipients, err
}

func (s *Store) saveMessageEnvelope(ctx context.Context, envelope domain.MessageEnvelope, withSyncEvent bool, recipients *[]string) (domain.MessageEnvelope, bool, int64, error) {
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
	if err := deleteExpiredMessageByIdempotency(ctx, tx, envelope.SenderDeviceID, envelope.IdempotencyKey, now); err != nil {
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
		payload, err := json.Marshal(messageSyncEventPayload(envelope))
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
		wakeExpiresAt := now.Add(pushWakeJobTTL)
		if envelope.ExpiresAt != nil && envelope.ExpiresAt.Before(wakeExpiresAt) {
			wakeExpiresAt = envelope.ExpiresAt.UTC()
		}
		if err := enqueuePushWakeJobs(ctx, tx, eventID, envelope.ConversationID, envelope.SenderAccountID, formatTime(now), formatTime(wakeExpiresAt)); err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
	}
	if recipients != nil && withSyncEvent {
		// Accounts that blocked the sender never see the envelope, on any read
		// path, so they are not sent it live either.
		rows, err := tx.QueryContext(ctx, `
			SELECT account_id FROM memberships
			WHERE conversation_id = ?
			  AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = memberships.account_id AND b.blocked_account_id = ?)
			ORDER BY account_id`, envelope.ConversationID, envelope.SenderAccountID)
		if err != nil {
			return domain.MessageEnvelope{}, false, 0, err
		}
		for rows.Next() {
			var accountID string
			if err := rows.Scan(&accountID); err != nil {
				rows.Close()
				return domain.MessageEnvelope{}, false, 0, err
			}
			*recipients = append(*recipients, accountID)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return domain.MessageEnvelope{}, false, 0, err
		}
		if err := rows.Close(); err != nil {
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

// MessageForAccount returns one unexpired envelope only when the requester is
// currently a member of its conversation. Missing and unauthorized IDs are
// intentionally indistinguishable so this lookup cannot probe other chats.
func (s *Store) MessageForAccount(ctx context.Context, messageID, accountID string) (domain.MessageEnvelope, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT me.id, me.conversation_id, me.sender_account_id, me.sender_device_id,
		       me.idempotency_key, me.ciphertext, me.crypto_protocol,
		       me.crypto_metadata_json, me.attachment_refs_json, me.reply_to_id,
		       me.thread_root_id, me.created_at, me.edited_at, me.deleted_at, me.expires_at
		FROM message_envelopes me
		JOIN memberships m ON m.conversation_id = me.conversation_id AND m.account_id = ?
		WHERE me.id = ?
		  AND NOT EXISTS (
		    SELECT 1 FROM account_blocks b
		    WHERE b.blocker_account_id = ? AND b.blocked_account_id = me.sender_account_id
		  )`, accountID, messageID, accountID)
	message, err := scanMessage(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.MessageEnvelope{}, ErrNotFound
		}
		return domain.MessageEnvelope{}, err
	}
	// An expired envelope that has not been pruned yet is reported as
	// expired, never returned: clients may pass over an application message
	// only with this proof (I33).
	if message.ExpiresAt != nil && !message.ExpiresAt.After(time.Now().UTC()) {
		return domain.MessageEnvelope{}, ErrMessageExpired
	}
	return message, nil
}

func (s *Store) UpdateMessageEnvelope(ctx context.Context, messageID, accountID string, ciphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, error) {
	envelope, _, err := s.updateMessageEnvelope(ctx, messageID, accountID, ciphertext, cryptoProtocol, cryptoMetadata, "")
	return envelope, err
}

func (s *Store) UpdateMessageEnvelopeWithSyncEvent(ctx context.Context, messageID, accountID string, ciphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, int64, error) {
	return s.updateMessageEnvelope(ctx, messageID, accountID, ciphertext, cryptoProtocol, cryptoMetadata, "message.envelope.edited")
}

func (s *Store) updateMessageEnvelope(ctx context.Context, messageID, accountID string, ciphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage, eventType string) (domain.MessageEnvelope, int64, error) {
	if len(ciphertext) == 0 || strings.TrimSpace(cryptoProtocol) == "" {
		return domain.MessageEnvelope{}, 0, ErrForbidden
	}
	if len(cryptoMetadata) == 0 {
		cryptoMetadata = json.RawMessage(`{}`)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	defer tx.Rollback()
	now := nowString()
	result, err := tx.ExecContext(ctx, `
		UPDATE message_envelopes
		SET ciphertext = ?, crypto_protocol = ?, crypto_metadata_json = ?, edited_at = ?
		WHERE id = ? AND sender_account_id = ? AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)
		  AND EXISTS (SELECT 1 FROM memberships m WHERE m.conversation_id = message_envelopes.conversation_id AND m.account_id = ?)`,
		ciphertext, cryptoProtocol, string(cryptoMetadata), now, messageID, accountID, now, accountID)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	envelope, err := messageAfterOwnedMutationTx(ctx, tx, messageID, result, now)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, envelope.ConversationID, messageSyncEventPayload(envelope), now)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	return envelope, eventID, nil
}

func (s *Store) DeleteMessageEnvelope(ctx context.Context, messageID, accountID string, markerCiphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, error) {
	envelope, _, err := s.deleteMessageEnvelope(ctx, messageID, accountID, markerCiphertext, cryptoProtocol, cryptoMetadata, "")
	return envelope, err
}

func (s *Store) DeleteMessageEnvelopeWithSyncEvent(ctx context.Context, messageID, accountID string, markerCiphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage) (domain.MessageEnvelope, int64, error) {
	return s.deleteMessageEnvelope(ctx, messageID, accountID, markerCiphertext, cryptoProtocol, cryptoMetadata, "message.envelope.deleted")
}

func (s *Store) deleteMessageEnvelope(ctx context.Context, messageID, accountID string, markerCiphertext []byte, cryptoProtocol string, cryptoMetadata json.RawMessage, eventType string) (domain.MessageEnvelope, int64, error) {
	if len(markerCiphertext) == 0 || strings.TrimSpace(cryptoProtocol) == "" {
		return domain.MessageEnvelope{}, 0, ErrForbidden
	}
	if len(cryptoMetadata) == 0 {
		cryptoMetadata = json.RawMessage(`{"deleted":true}`)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	defer tx.Rollback()
	now := nowString()
	result, err := tx.ExecContext(ctx, `
		UPDATE message_envelopes
		SET ciphertext = ?, crypto_protocol = ?, crypto_metadata_json = ?, deleted_at = ?, attachment_refs_json = '[]'
		WHERE id = ? AND sender_account_id = ? AND deleted_at IS NULL AND (expires_at IS NULL OR expires_at > ?)
		  AND EXISTS (SELECT 1 FROM memberships m WHERE m.conversation_id = message_envelopes.conversation_id AND m.account_id = ?)`,
		markerCiphertext, cryptoProtocol, string(cryptoMetadata), now, messageID, accountID, now, accountID)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	envelope, err := messageAfterOwnedMutationTx(ctx, tx, messageID, result, now)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	if err := releaseMessageAttachments(ctx, tx, messageID); err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	// The created and edited events still hold the ciphertext the delete
	// replaced. They are hidden from sync from now on (syncEventVisibleTo),
	// and their copies go here, the way expiry removes them. The deleted
	// event, written below, carries the marker and stays visible. Every
	// copy is at or after the created event, so the update reads only the
	// conversation's events from there on (idx_sync_events_conversation),
	// not its whole retained history.
	from, err := messageCreatedEventID(ctx, tx, envelope.ConversationID, messageID, envelope.CreatedAt)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	if _, err := tx.ExecContext(ctx, redactMessageSyncEventsSQL+`
		WHERE conversation_id = ? AND id >= ? AND event_type IN (`+messageVersionEventTypes+`)
		  AND json_extract(payload_json, '$.message_id') = ?
		  AND json_extract(payload_json, '$.envelope') IS NOT NULL`, envelope.ConversationID, from, messageID); err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, envelope.ConversationID, messageSyncEventPayload(envelope), now)
	if err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return domain.MessageEnvelope{}, 0, err
	}
	return envelope, eventID, nil
}

// messageCreatedEventID is the id of the message's created sync event, or 0
// when retention already pruned it. The event was written in the message's
// own transaction with the message's created_at, so the lookup walks the
// conversation's events back from the newest and stops there; that is the
// events after the message, not the conversation's whole history.
func messageCreatedEventID(ctx context.Context, tx *sql.Tx, conversationID, messageID string, createdAt time.Time) (int64, error) {
	var id int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM sync_events
		WHERE conversation_id = ? AND event_type = 'message.envelope.created' AND created_at = ?
		  AND json_extract(payload_json, '$.message_id') = ?
		ORDER BY id DESC LIMIT 1`, conversationID, formatTime(createdAt), messageID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return id, err
}

// releaseMessageAttachments drops the attachment links of a message that was
// just turned into a tombstone, deletes the attachments nothing links any
// more, and queues their blobs for deletion, all in the caller's transaction.
// An attachment links to one message at most (message_attachments.attachment_id
// is unique), so every attachment of the message goes. The tombstone's own
// attachment_refs_json was cleared by the UPDATE.
func releaseMessageAttachments(ctx context.Context, tx *sql.Tx, messageID string) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT a.id, a.storage_key
		FROM message_attachments ma
		JOIN attachment_envelopes a ON a.id = ma.attachment_id
		WHERE ma.message_id = ?`, messageID)
	if err != nil {
		return err
	}
	type released struct{ id, storageKey string }
	var attachments []released
	for rows.Next() {
		var item released
		if err := rows.Scan(&item.id, &item.storageKey); err != nil {
			rows.Close()
			return err
		}
		attachments = append(attachments, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if len(attachments) == 0 {
		return nil
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM message_attachments WHERE message_id = ?`, messageID); err != nil {
		return err
	}
	for _, item := range attachments {
		result, err := tx.ExecContext(ctx, `
			DELETE FROM attachment_envelopes
			WHERE id = ? AND NOT EXISTS (SELECT 1 FROM message_attachments ma WHERE ma.attachment_id = attachment_envelopes.id)`, item.id)
		if err != nil {
			return err
		}
		if deleted, err := result.RowsAffected(); err != nil {
			return err
		} else if deleted == 1 {
			if err := enqueueBlobDeletion(ctx, tx, item.storageKey); err != nil {
				return err
			}
		}
	}
	return nil
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

func messageAfterOwnedMutationTx(ctx context.Context, tx *sql.Tx, messageID string, result sql.Result, now string) (domain.MessageEnvelope, error) {
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	if rows == 0 {
		var exists int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM message_envelopes WHERE id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, now).Scan(&exists); err != nil {
			return domain.MessageEnvelope{}, err
		}
		if exists == 0 {
			return domain.MessageEnvelope{}, ErrNotFound
		}
		return domain.MessageEnvelope{}, ErrForbidden
	}
	return scanMessage(tx.QueryRowContext(ctx, `SELECT id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, reply_to_id, thread_root_id, created_at, edited_at, deleted_at, expires_at FROM message_envelopes WHERE id = ?`, messageID))
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
			AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = message_envelopes.sender_account_id)
			ORDER BY created_at DESC, id DESC LIMIT ?`,
			conversationID, nowString(), cursorAt, cursorAt, opts.BeforeID, accountID, limit)
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
			AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = message_envelopes.sender_account_id)
			ORDER BY created_at ASC, id ASC LIMIT ?`,
			conversationID, nowString(), cursorAt, cursorAt, opts.AfterID, accountID, limit)
		if err != nil {
			return nil, err
		}
	default:
		rows, err = s.db.QueryContext(ctx, `SELECT `+cols+` FROM message_envelopes
			WHERE conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)
			AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = message_envelopes.sender_account_id)
			ORDER BY created_at DESC, id DESC LIMIT ?`, conversationID, nowString(), accountID, limit)
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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := deleteExpiredMessageByIdempotency(ctx, tx, deviceID, key, now); err != nil {
		return err
	}
	return tx.Commit()
}

// deleteExpiredMessageByIdempotency removes the device's expired envelope for
// key, if there is one, together with the ciphertext copies in its sync
// events, in the caller's transaction.
func deleteExpiredMessageByIdempotency(ctx context.Context, tx *sql.Tx, deviceID, key string, now time.Time) error {
	var messageID, conversationID string
	err := tx.QueryRowContext(ctx, `SELECT id, conversation_id FROM message_envelopes WHERE sender_device_id = ? AND idempotency_key = ? AND expires_at IS NOT NULL AND expires_at <= ?`, deviceID, key, formatTime(now.UTC())).Scan(&messageID, &conversationID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, redactMessageSyncEventsSQL+`
		WHERE conversation_id = ? AND event_type IN (`+messageEnvelopeEventTypes+`)
		  AND json_extract(payload_json, '$.message_id') = ?
		  AND json_extract(payload_json, '$.envelope') IS NOT NULL`, conversationID, messageID); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `DELETE FROM message_envelopes WHERE id = ?`, messageID)
	return err
}

// messageEnvelopeEventTypes lists the sync events that hold a copy of a
// message envelope, ciphertext included (messageSyncEventPayload).
const messageEnvelopeEventTypes = `'message.envelope.created', 'message.envelope.edited', 'message.envelope.deleted'`

// messageVersionEventTypes lists the message events whose envelope copy a
// delete supersedes: every one but the deleted event itself.
const messageVersionEventTypes = `'message.envelope.created', 'message.envelope.edited'`

// redactMessageSyncEventsSQL starts an UPDATE that cuts a message event down
// to the identifiers readers still need. The row and its id stay, so a cursor
// on it keeps working; the ciphertext and every other envelope field go. The
// sender stays so syncEventBlockedFor keeps hiding the event from accounts
// that blocked it.
const redactMessageSyncEventsSQL = `UPDATE sync_events SET payload_json = json_object(
	'message_id', json_extract(payload_json, '$.message_id'),
	'conversation_id', COALESCE(json_extract(payload_json, '$.conversation_id'), conversation_id),
	'sender_account_id', COALESCE(json_extract(payload_json, '$.envelope.sender_account_id'), json_extract(payload_json, '$.sender_account_id')),
	'redacted', 1)`

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
	if _, err := tx.ExecContext(ctx, `CREATE TEMP TABLE prune_expired_message_ids(id TEXT PRIMARY KEY)`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO prune_expired_message_ids(id)
		SELECT id FROM message_envelopes
		WHERE expires_at IS NOT NULL AND expires_at <= ?
		ORDER BY expires_at, id LIMIT 500`, cutoff); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `CREATE TEMP TABLE prune_expired_attachment_ids(id TEXT PRIMARY KEY)`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `CREATE TEMP TABLE prune_expired_storage_keys(storage_key TEXT PRIMARY KEY)`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO prune_expired_attachment_ids(id)
		SELECT DISTINCT attachment_id FROM message_attachments
		WHERE message_id IN (SELECT id FROM prune_expired_message_ids)`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO prune_expired_storage_keys(storage_key)
		SELECT DISTINCT a.storage_key
		FROM attachment_envelopes a
		JOIN prune_expired_attachment_ids pa ON pa.id = a.id`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM message_attachments
		WHERE message_id IN (SELECT id FROM prune_expired_message_ids)`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM attachment_envelopes
		WHERE id IN (SELECT id FROM prune_expired_attachment_ids)
		  AND NOT EXISTS (SELECT 1 FROM message_attachments ma WHERE ma.attachment_id = attachment_envelopes.id)`); err != nil {
		return 0, nil, err
	}
	rows, err := tx.QueryContext(ctx, `
		SELECT storage_key FROM prune_expired_storage_keys p
		WHERE NOT EXISTS (SELECT 1 FROM attachment_envelopes a WHERE a.storage_key = p.storage_key)`)
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
	// The envelope rows are about to go, and the sync events that copied them
	// must not keep the ciphertext. Restricting by conversation lets the
	// update use idx_sync_events_conversation.
	if _, err := tx.ExecContext(ctx, redactMessageSyncEventsSQL+`
		WHERE conversation_id IN (SELECT conversation_id FROM message_envelopes WHERE id IN (SELECT id FROM prune_expired_message_ids))
		  AND event_type IN (`+messageEnvelopeEventTypes+`)
		  AND json_extract(payload_json, '$.message_id') IN (SELECT id FROM prune_expired_message_ids)
		  AND json_extract(payload_json, '$.envelope') IS NOT NULL`); err != nil {
		return 0, nil, err
	}
	backfillTo, err := s.redactOrphanedMessageEvents(ctx, tx)
	if err != nil {
		return 0, nil, err
	}
	result, err := tx.ExecContext(ctx, `
		DELETE FROM message_envelopes
		WHERE id IN (SELECT id FROM prune_expired_message_ids)`)
	if err != nil {
		return 0, nil, err
	}
	removed, err := result.RowsAffected()
	if err != nil {
		return 0, nil, err
	}
	orphanCutoff := formatTime(now.UTC().Add(-OrphanedAttachmentGrace))
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
	for _, storageKey := range storageKeys {
		if err := enqueueBlobDeletion(ctx, tx, storageKey); err != nil {
			return 0, nil, err
		}
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE prune_expired_attachment_ids`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE prune_expired_storage_keys`); err != nil {
		return 0, nil, err
	}
	if _, err := tx.ExecContext(ctx, `DROP TABLE prune_expired_message_ids`); err != nil {
		return 0, nil, err
	}
	if err := tx.Commit(); err != nil {
		return 0, nil, err
	}
	s.redactMu.Lock()
	s.redactCursor = backfillTo
	s.redactMu.Unlock()
	return removed, storageKeys, nil
}

// redactOrphanedMessageEvents redacts the message events whose envelope row is
// already gone but whose payload still holds the envelope: the copies left by
// expiries pruned before events were redacted with them. It also redacts the
// created and edited events of a message deleted before deletes redacted
// them, which sync already hides (syncEventVisibleTo). Each call starts at
// the first event after the cursor and looks at the next redactBackfillWindow
// event ids, so the work per sweep is bounded however large sync_events is,
// and a gap left by PruneSyncEvents is jumped, not crawled. The cursor wraps
// to the start when nothing is left after it. It returns the cursor for the
// next call, which the caller stores once its transaction commits.
func (s *Store) redactOrphanedMessageEvents(ctx context.Context, tx *sql.Tx) (int64, error) {
	s.redactMu.Lock()
	from := s.redactCursor
	s.redactMu.Unlock()
	var first sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MIN(id) FROM sync_events WHERE id > ?`, from).Scan(&first); err != nil {
		return 0, err
	}
	if !first.Valid {
		return 0, nil
	}
	to := first.Int64 + redactBackfillWindow - 1
	if _, err := tx.ExecContext(ctx, redactMessageSyncEventsSQL+`
		WHERE id >= ? AND id <= ? AND event_type IN (`+messageEnvelopeEventTypes+`)
		  AND json_extract(payload_json, '$.envelope') IS NOT NULL
		  AND NOT EXISTS (SELECT 1 FROM message_envelopes me WHERE me.id = json_extract(payload_json, '$.message_id')
		                  AND (me.deleted_at IS NULL OR event_type = 'message.envelope.deleted'))`, first.Int64, to); err != nil {
		return 0, err
	}
	return to, nil
}

// redactBackfillWindow is how many event ids one sweep's backfill covers.
const redactBackfillWindow = 2000

// PruneSyncEvents deletes sync events older than the cutoff. Returns the
// number of rows removed. Intended to be run periodically by a background
// sweeper so the table doesn't grow unbounded.
func (s *Store) PruneSyncEvents(ctx context.Context, olderThan time.Time) (int64, error) {
	return s.pruneEventRows(ctx, `DELETE FROM sync_events WHERE id IN (SELECT id FROM sync_events WHERE created_at < ? ORDER BY id LIMIT 500)`, olderThan)
}

// PruneAuditEvents deletes audit events older than the cutoff.
func (s *Store) PruneAuditEvents(ctx context.Context, olderThan time.Time) (int64, error) {
	return s.pruneEventRows(ctx, `DELETE FROM audit_events WHERE id IN (SELECT id FROM audit_events WHERE created_at < ? ORDER BY id LIMIT 500)`, olderThan)
}

func (s *Store) pruneEventRows(ctx context.Context, query string, olderThan time.Time) (int64, error) {
	var total int64
	for {
		result, err := s.db.ExecContext(ctx, query, formatTime(olderThan.UTC()))
		if err != nil {
			return total, err
		}
		removed, err := result.RowsAffected()
		if err != nil {
			return total, err
		}
		total += removed
		if removed < 500 {
			return total, nil
		}
		timer := time.NewTimer(5 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return total, ctx.Err()
		case <-timer.C:
		}
	}
}

// RecordAuditEvent appends a metadata-only audit row. Callers MUST NOT pass
// message content, ciphertext, or any field that would defeat the privacy
// promise that admins cannot read user data.
func (s *Store) RecordAuditEvent(ctx context.Context, actorAccountID *string, eventType string, metadata interface{}) error {
	return insertAuditEvent(ctx, s.db, actorAccountID, eventType, metadata)
}

// AuditEvent is a metadata-only audit row that a store method writes in the
// same transaction as the change it records, so the change is never
// persisted without it. The same rule applies as for RecordAuditEvent: no
// message content, ciphertext or secrets in Metadata.
type AuditEvent struct {
	Type     string
	Metadata interface{}
}

func insertAuditEvent(ctx context.Context, exec syncEventExecer, actorAccountID *string, eventType string, metadata interface{}) error {
	payload := json.RawMessage(`{}`)
	if metadata != nil {
		b, err := json.Marshal(metadata)
		if err != nil {
			return err
		}
		payload = b
	}
	_, err := exec.ExecContext(ctx, `INSERT INTO audit_events(actor_account_id, event_type, metadata_json, created_at) VALUES(?, ?, ?, ?)`, nullableString(actorAccountID), eventType, string(payload), nowString())
	return err
}

func (s *Store) SaveSyncEvent(ctx context.Context, eventType string, accountID *string, conversationID string, payload interface{}) (int64, error) {
	return insertSyncEvent(ctx, s.db, eventType, accountID, conversationID, payload, nowString())
}

// Message sync events carry the immutable ciphertext envelope as it existed
// at that event version. A later edit must never make replay fetch a newer
// representation for an older cursor position.
func messageSyncEventPayload(envelope domain.MessageEnvelope) map[string]interface{} {
	return map[string]interface{}{
		"message_id":      envelope.ID,
		"conversation_id": envelope.ConversationID,
		"envelope":        envelope,
	}
}

type syncEventExecer interface {
	ExecContext(context.Context, string, ...interface{}) (sql.Result, error)
}

func insertOptionalSyncEvent(ctx context.Context, execer syncEventExecer, eventType string, accountID *string, conversationID string, payload interface{}, createdAt string) (int64, error) {
	if eventType == "" {
		return 0, nil
	}
	return insertSyncEvent(ctx, execer, eventType, accountID, conversationID, payload, createdAt)
}

func insertSyncEvent(ctx context.Context, execer syncEventExecer, eventType string, accountID *string, conversationID string, payload interface{}, createdAt string) (int64, error) {
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	result, err := execer.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES(?, ?, ?, ?, ?)`, eventType, nullableString(accountID), nullableEmptyString(conversationID), string(payloadBytes), createdAt)
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

// ListSyncEvents returns the events after afterID that the account's
// device may see: account events (a Welcome only for its own device) and
// events of its conversations, where encrypted ones follow the device's MLS
// join cursor (card I51). It returns ErrSyncCursorExpired when retention
// pruned an event after afterID that the device could have been sent
// (syncCursorExpired).
func (s *Store) ListSyncEvents(ctx context.Context, accountID, deviceID string, afterID int64, limit int) ([]domain.SyncEvent, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	events, err := s.listSyncEventsPage(ctx, accountID, deviceID, afterID, limit)
	if err != nil {
		return nil, err
	}
	// The expiry check runs after the page, which is one statement and so
	// one snapshot: a prune that removed events the page lacks committed
	// before the page was read, so its marks are visible here. Checked
	// first, a prune landing between the check and the page would leave a
	// silent gap. Only a cursor past the start can have expired.
	if afterID > 0 {
		expired, err := s.syncCursorExpired(ctx, accountID, deviceID, afterID)
		if err != nil {
			return nil, err
		}
		if expired {
			return nil, ErrSyncCursorExpired
		}
	}
	return events, nil
}

func (s *Store) listSyncEventsPage(ctx context.Context, accountID, deviceID string, afterID int64, limit int) ([]domain.SyncEvent, error) {
	// The query streams candidates in id order and has no LIMIT, since
	// hidden ones do not count towards the page: the page ends here, after
	// limit visible events, and closing rows stops the merge.
	rows, err := s.db.QueryContext(ctx, listSyncEventsQuery, accountID, afterID, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var events []domain.SyncEvent
	candidate := &syncCandidateScanner{rows: rows}
	last := afterID
	for len(events) < limit && rows.Next() {
		event, err := scanSyncEvent(candidate)
		if err != nil {
			return nil, err
		}
		// The merge has no outer ORDER BY: it relies on SQLite emitting
		// the queue in id order. Clients refuse a page out of order, so
		// fail the page here rather than send one.
		if event.ID <= last {
			return nil, fmt.Errorf("sync merge emitted event %d after %d", event.ID, last)
		}
		last = event.ID
		if candidate.visible {
			events = append(events, event)
		}
	}
	return events, rows.Err()
}

// syncCursorExpired reports whether retention pruned an event after afterID
// that device deviceID of account accountID could have been sent. It reads
// the prune watermarks that migration 0044's triggers keep:
//
//   - a cursor at or past the highest id ever pruned has lost nothing (one
//     primary-key read; the usual case, since the newest pruned event is
//     about the event retention period old);
//   - otherwise syncPruneMarksExpiredQuery: point reads for the account's
//     marks and one primary-key read per membership;
//   - a cursor below legacy_through, the ids pruned before the marks
//     existed, also gets the old test (legacySyncCursorExpiredQuery).
//
// It errs only towards expired; docs/operations.md lists when.
func (s *Store) syncCursorExpired(ctx context.Context, accountID, deviceID string, afterID int64) (bool, error) {
	var legacyThrough, prunedThrough int64
	err := s.db.QueryRowContext(ctx, `SELECT legacy_through, pruned_through FROM sync_prune_state WHERE id = 1`).Scan(&legacyThrough, &prunedThrough)
	known := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	if known && afterID >= prunedThrough {
		return false, nil
	}
	var expired bool
	if err := s.db.QueryRowContext(ctx, syncPruneMarksExpiredQuery, accountID, afterID, deviceID).Scan(&expired); err != nil {
		return false, err
	}
	// Without the state row nothing says where the marks start, so the old
	// test runs too.
	if expired || (known && afterID >= legacyThrough) {
		return expired, nil
	}
	if err := s.db.QueryRowContext(ctx, legacySyncCursorExpiredQuery, accountID, afterID).Scan(&expired); err != nil {
		return false, err
	}
	return expired, nil
}

// syncPruneMarksExpiredQuery is true when a pruned event after cursor ?2
// could have gone to device ?3 of account ?1: its account's events for every
// device or for ?3, or the events of a conversation it is a member of. A
// conversation's MLS-filtered events (roster_filtered) count only when the
// device's roster row would have shown the newest of them that was pruned,
// mark M: M > joined_after_event_id and the device not removed before M. When
// it was removed before M, an older pruned event inside its window may still
// be one it lost, so the window counts if it reaches past the cursor.
// Membership is the current one, as in listSyncEventsQuery: a conversation
// the account left sends it nothing any more, and its own membership.left
// event is an account event. Blocks and joined_epoch are not applied, so a
// pruned event of a blocked sender, or a late message from before the
// device's first epoch, still counts (conservative).
//
// The membership walk is on memberships(account_id, conversation_id) with a
// primary-key read of each mark; the account marks are two primary-key reads.
var syncPruneMarksExpiredQuery = `SELECT EXISTS (
	  SELECT 1 FROM sync_prune_account_marks
	  WHERE account_id = ?1 AND device_id IN ('', ?3) AND pruned_through > ?2
	) OR EXISTS (
	  SELECT 1 FROM memberships m
	  JOIN sync_prune_conversation_marks k ON k.conversation_id = m.conversation_id
	  WHERE m.account_id = ?1 AND k.pruned_through > ?2
	    AND (k.roster_filtered = 0
	      OR NOT EXISTS (SELECT 1 FROM conversation_mls_groups jg WHERE jg.conversation_id = k.conversation_id)
	      OR EXISTS (SELECT 1 FROM conversation_mls_devices jd
	        WHERE jd.conversation_id = k.conversation_id AND jd.device_id = ?3
	          AND k.pruned_through > jd.joined_after_event_id
	          AND (jd.removed_after_event_id IS NULL
	            OR (jd.removed_after_event_id > ?2 AND jd.removed_after_event_id > jd.joined_after_event_id))))
	)`

// syncCandidateScanner reads a listSyncEventsQuery row: the visible flag,
// then the columns scanSyncEvent reads.
type syncCandidateScanner struct {
	rows    *sql.Rows
	visible bool
	dest    []interface{}
}

func (c *syncCandidateScanner) Scan(dest ...interface{}) error {
	c.dest = append(append(c.dest[:0], &c.visible), dest...)
	return c.rows.Scan(c.dest...)
}

// syncEventVisibleTo is true when the conversation event se may go to the
// device ?3 of account ?1: its encrypted events follow the device's MLS
// join cursor, and nothing comes from an account ?1 blocked.
//
// A message event also needs its envelope row: once the message expired or
// the row is gone, the event is hidden even from a cursor older than it, so
// an expired envelope is never replayed. Once the message is deleted, only
// its deleted event (the marker) is served; the created and edited events,
// whose ciphertext the delete redacted, are hidden the same way. The clock
// is SQLite's, in the stored fixed-width format, because the query takes no
// time parameter.
var syncEventVisibleTo = `(NOT (se.event_type = 'mls.message.created' OR se.event_type LIKE 'message.envelope.%'
	        OR se.event_type LIKE 'call.%')
	   OR ` + mlsJoinFilterEventFor("?3") + `)
	AND NOT ` + syncEventBlockedFor("?1") + `
	AND (se.event_type NOT LIKE 'message.envelope.%' OR EXISTS (
	  SELECT 1 FROM message_envelopes live
	  WHERE live.id = json_extract(se.payload_json, '$.message_id')
	    AND (live.expires_at IS NULL OR live.expires_at > ` + sqlNowText + `)
	    AND (live.deleted_at IS NULL OR se.event_type = 'message.envelope.deleted')))`

// sqlNowText is the current time in formatTime's layout, to the millisecond.
const sqlNowText = `(strftime('%Y-%m-%dT%H:%M:%S', 'now') || substr(strftime('%f', 'now'), 3) || '000000Z')`

// listSyncEventsQuery streams, in id order, the events after ?2 that could
// go to device ?3 of account ?1, each with a flag that says whether it may
// see it. Parameters: ?1 account, ?2 cursor, ?3 device. ListSyncEvents
// stops reading after a page of visible rows.
//
// It is a k-way merge (T49 follow-up). The recursive CTE is a priority
// queue ordered by id with one chain per membership and one for the
// account's own events: first_events seeds each chain with its first event
// after the cursor, and each row taken out queues the next event of the
// same chain, found on idx_sync_events_conversation or
// idx_sync_events_account. Visibility (the MLS join cursor and blocks) is
// computed for each row as it is queued and only flags it, so no chain
// searches ahead for a visible event. A page therefore reads one probe per
// membership plus the events of the account's conversations, and its own
// events, inside the page's id range, hidden ones included, and nothing
// past it. Filtering inside the chains made every page search a run of
// hidden events forward from the cursor again, so paging past one was
// quadratic (testing/evidence/benchmarks-t49.md). The former single scan
// walked every conversation event on the instance after the cursor.
//
// SQLite runs candidates as a co-routine (EXPLAIN QUERY PLAN: CO-ROUTINE
// candidates, then SCAN q), so the queue advances only as rows are read and
// the caller's early close is what ends the merge; a LIMIT here would count
// hidden rows. The CROSS JOIN keeps candidates the outer loop.
//
// first_events is MATERIALIZED so its subquery runs once per chain. The
// unary + keeps account_id IS NULL off idx_sync_events_account.
var listSyncEventsQuery = `
	WITH RECURSIVE
	first_events(id, chain) AS MATERIALIZED (
	  SELECT (SELECT se.id FROM sync_events se
	          WHERE se.conversation_id = m.conversation_id AND +se.account_id IS NULL AND se.id > ?2
	          ORDER BY se.id ASC LIMIT 1), m.conversation_id
	  FROM memberships m WHERE m.account_id = ?1 AND m.conversation_id IS NOT NULL
	  UNION ALL
	  SELECT (SELECT id FROM sync_events
	          WHERE account_id = ?1 AND id > ?2 AND (device_id IS NULL OR device_id = ?3)
	          ORDER BY id ASC LIMIT 1), NULL
	),
	candidates(id, chain, visible) AS (
	  SELECT se.id, f.chain, CASE WHEN f.chain IS NULL THEN 1 ELSE (` + syncEventVisibleTo + `) END
	  FROM first_events f JOIN sync_events se ON se.id = f.id
	  UNION ALL
	  SELECT se.id, q.chain, CASE WHEN q.chain IS NULL THEN 1 ELSE (` + syncEventVisibleTo + `) END
	  FROM candidates q
	  JOIN sync_events se ON se.id = CASE WHEN q.chain IS NULL
	    THEN (SELECT n.id FROM sync_events n
	          WHERE n.account_id = ?1 AND n.id > q.id AND (n.device_id IS NULL OR n.device_id = ?3)
	          ORDER BY n.id ASC LIMIT 1)
	    ELSE (SELECT n.id FROM sync_events n
	          WHERE n.conversation_id = q.chain AND +n.account_id IS NULL AND n.id > q.id
	          ORDER BY n.id ASC LIMIT 1) END
	  ORDER BY 1
	)
	SELECT q.visible, se.id, se.event_type, se.account_id, se.conversation_id,
	       CASE WHEN q.visible THEN se.payload_json ELSE '' END, se.created_at
	FROM candidates q CROSS JOIN sync_events se ON se.id = q.id`

// syncEventBlockedFor is true when the conversation event se is hidden from
// blocker: it comes from an account that blocker blocked or, for a read
// receipt (D48: a block hides receipts in both directions), from an account
// that blocked blocker. blocker is SQL text (a column or a positional
// parameter), never a value.
//
// A message event names its sender through the live envelope row; when that
// row is gone (expired and pruned, or replaced by an idempotent retry) the
// sender stored in the event payload stands in, so a block keeps hiding the
// event instead of failing open.
func syncEventBlockedFor(blocker string) string {
	return `(EXISTS (
		SELECT 1 FROM account_blocks b
		WHERE b.blocker_account_id = ` + blocker + `
		  AND b.blocked_account_id = CASE
		    WHEN se.event_type LIKE 'message.%' THEN COALESCE(
		      (SELECT sender_account_id FROM message_envelopes WHERE id = json_extract(se.payload_json, '$.message_id')),
		      json_extract(se.payload_json, '$.envelope.sender_account_id'),
		      json_extract(se.payload_json, '$.sender_account_id'))
		    WHEN se.event_type LIKE 'reaction.%' OR se.event_type = 'read_receipt.updated' THEN json_extract(se.payload_json, '$.account_id')
		    WHEN se.event_type LIKE 'call.%' THEN json_extract(se.payload_json, '$.created_by')
		    ELSE NULL
		  END
	) OR (se.event_type = 'read_receipt.updated' AND EXISTS (
		SELECT 1 FROM account_blocks rb
		WHERE rb.blocker_account_id = json_extract(se.payload_json, '$.account_id')
		  AND rb.blocked_account_id = ` + blocker + `
	)))`
}

// syncBoundsQuery returns the lowest and highest sync event id the account
// may see: its account events plus the unblocked events of its
// conversations. Each conversation is walked on idx_sync_events_conversation
// from the relevant end and stops at its first visible event, so the block
// predicate runs only on the few rows at each edge instead of on every event
// on the instance (T49A). The unary + keeps account_id IS NULL off
// idx_sync_events_account, which would scan every conversation event.
var syncBoundsQuery = `SELECT ` + syncOldestExpr + `, ` + syncLatestExpr

// legacySyncCursorExpiredQuery is the cursor test from before migration
// 0044, kept for cursors into ids pruned before the marks existed. It is
// true when cursor ?2 of account ?1 is older than the oldest event the
// account may see (syncOldestExpr) less one. Sync event ids are global, so
// other accounts' events in that gap make it refuse cursors that missed
// nothing; it never passes one that missed something. That bound walks each
// conversation from its start to its first unblocked event. While the
// cursor's own event is still there and counts towards the bound, the bound
// is at most the cursor, so one primary-key read settles it and the CASE
// never evaluates the bound.
var legacySyncCursorExpiredQuery = `SELECT CASE WHEN EXISTS (
	  SELECT 1 FROM sync_events se
	  WHERE se.id = ?2 AND (se.account_id = ?1 OR (se.account_id IS NULL
	    AND EXISTS (SELECT 1 FROM memberships m WHERE m.account_id = ?1 AND m.conversation_id = se.conversation_id)
	    AND NOT ` + syncEventBlockedFor("?1") + `))
	) THEN 0 ELSE COALESCE(?2 < ` + syncOldestExpr + ` - 1, 0) END`

var syncOldestExpr = `
	  (SELECT MIN(v) FROM (
	     SELECT MIN(id) AS v FROM sync_events WHERE account_id = ?1
	     UNION ALL
	     SELECT (SELECT se.id FROM sync_events se
	             WHERE se.conversation_id = m.conversation_id AND +se.account_id IS NULL
	               AND NOT ` + syncEventBlockedFor("?1") + `
	             ORDER BY se.id ASC LIMIT 1)
	     FROM memberships m WHERE m.account_id = ?1 AND m.conversation_id IS NOT NULL
	  ))`

var syncLatestExpr = `
	  (SELECT MAX(v) FROM (
	     SELECT MAX(id) AS v FROM sync_events WHERE account_id = ?1
	     UNION ALL
	     SELECT (SELECT se.id FROM sync_events se
	             WHERE se.conversation_id = m.conversation_id AND +se.account_id IS NULL
	               AND NOT ` + syncEventBlockedFor("?1") + `
	             ORDER BY se.id DESC LIMIT 1)
	     FROM memberships m WHERE m.account_id = ?1 AND m.conversation_id IS NOT NULL
	  ))`

func (s *Store) SyncBounds(ctx context.Context, accountID string) (string, int64, int64, error) {
	var epoch string
	if err := s.db.QueryRowContext(ctx, `SELECT epoch FROM sync_state WHERE id = 1`).Scan(&epoch); err != nil {
		return "", 0, 0, err
	}
	var oldest, latest sql.NullInt64
	if err := s.db.QueryRowContext(ctx, syncBoundsQuery, accountID).Scan(&oldest, &latest); err != nil {
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
