package storage

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	_ "modernc.org/sqlite"

	"private-messenger/server/internal/domain"
)

// RecoveryCapabilityLifetime bounds the window in which a recovery capability
// can be used. A transfer may finish after this deadline only when it was
// already leased before expiry; a new or resumed transfer cannot start then.
const RecoveryCapabilityLifetime = 15 * time.Minute

// RecoveryLeaseLifetime is deliberately shorter than the capability lifetime
// so a crashed process cannot strand a resumable transfer until expiry.
const RecoveryLeaseLifetime = 2 * time.Minute

// RecoveryTransfer is an approved, serialized range of an encrypted backup.
// LeaseID is internal state and must never be returned to a client or logged.
type RecoveryTransfer struct {
	Backup      domain.BackupBlob
	LeaseID     string
	StartOffset int64
}

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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	defer tx.Rollback()
	attachment, err := scanAttachment(tx.QueryRowContext(ctx, `
		SELECT a.id, a.owner_account_id, a.conversation_id, a.storage_key, a.ciphertext_sha256, a.size_bytes, a.crypto_metadata_json, a.created_at
		FROM attachment_envelopes a
		LEFT JOIN memberships m ON m.conversation_id = a.conversation_id AND m.account_id = ?
		WHERE a.id = ? AND (a.owner_account_id = ? OR m.id IS NOT NULL)`, accountID, id, accountID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.AttachmentEnvelope{}, ErrNotFound
	}
	if err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	if attachment.OwnerAccountID != accountID {
		return domain.AttachmentEnvelope{}, ErrForbidden
	}
	result, err := tx.ExecContext(ctx, `DELETE FROM attachment_envelopes WHERE id = ? AND owner_account_id = ?`, id, accountID)
	if err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return domain.AttachmentEnvelope{}, ErrNotFound
	}
	if err := enqueueBlobDeletion(ctx, tx, attachment.StorageKey); err != nil {
		return domain.AttachmentEnvelope{}, err
	}
	return attachment, tx.Commit()
}

func (s *Store) CreateReaction(ctx context.Context, messageID, accountID string, reactionCiphertext []byte) error {
	_, _, err := s.createReaction(ctx, messageID, accountID, reactionCiphertext, "")
	return err
}

func (s *Store) CreateReactionWithSyncEvent(ctx context.Context, messageID, accountID string, reactionCiphertext []byte) (string, int64, error) {
	return s.createReaction(ctx, messageID, accountID, reactionCiphertext, "reaction.created")
}

func (s *Store) createReaction(ctx context.Context, messageID, accountID string, reactionCiphertext []byte, eventType string) (string, int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback()
	var conversationID string
	if err := tx.QueryRowContext(ctx, `SELECT conversation_id FROM message_envelopes WHERE id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, nowString()).Scan(&conversationID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", 0, ErrNotFound
		}
		return "", 0, err
	}
	var member bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?)`, conversationID, accountID).Scan(&member); err != nil {
		return "", 0, err
	}
	if !member {
		return "", 0, ErrNotMember
	}
	id, err := domain.NewID("react")
	if err != nil {
		return "", 0, err
	}
	now := nowString()
	if _, err := tx.ExecContext(ctx, `INSERT INTO reactions(id, message_id, account_id, reaction_ciphertext, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(message_id, account_id) DO UPDATE SET reaction_ciphertext = excluded.reaction_ciphertext, created_at = excluded.created_at`, id, messageID, accountID, reactionCiphertext, now); err != nil {
		return "", 0, err
	}
	payload := map[string]string{"message_id": messageID, "account_id": accountID}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, conversationID, payload, now)
	if err != nil {
		return "", 0, err
	}
	if err := tx.Commit(); err != nil {
		return "", 0, err
	}
	return conversationID, eventID, nil
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
	rows, err := s.db.QueryContext(ctx, `SELECT id, message_id, account_id, reaction_ciphertext, created_at FROM reactions WHERE message_id = ? AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = reactions.account_id) ORDER BY created_at, id`, messageID, accountID)
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
	conversationID, _, err := s.deleteReaction(ctx, messageID, accountID, "")
	return conversationID, err
}

func (s *Store) DeleteReactionWithSyncEvent(ctx context.Context, messageID, accountID string) (string, int64, error) {
	return s.deleteReaction(ctx, messageID, accountID, "reaction.deleted")
}

func (s *Store) deleteReaction(ctx context.Context, messageID, accountID, eventType string) (string, int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback()
	var conversationID string
	if err := tx.QueryRowContext(ctx, `SELECT conversation_id FROM message_envelopes WHERE id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, nowString()).Scan(&conversationID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", 0, ErrNotFound
		}
		return "", 0, err
	}
	result, err := tx.ExecContext(ctx, `DELETE FROM reactions WHERE message_id = ? AND account_id = ?`, messageID, accountID)
	if err != nil {
		return "", 0, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return "", 0, ErrNotFound
	}
	now := nowString()
	payload := map[string]string{"message_id": messageID, "account_id": accountID}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, conversationID, payload, now)
	if err != nil {
		return "", 0, err
	}
	if err := tx.Commit(); err != nil {
		return "", 0, err
	}
	return conversationID, eventID, nil
}

func (s *Store) MarkRead(ctx context.Context, conversationID, accountID, messageID string) error {
	_, err := s.markRead(ctx, conversationID, accountID, messageID, "")
	return err
}

func (s *Store) MarkReadWithSyncEvent(ctx context.Context, conversationID, accountID, messageID string) (int64, error) {
	return s.markRead(ctx, conversationID, accountID, messageID, "read_receipt.updated")
}

func (s *Store) markRead(ctx context.Context, conversationID, accountID, messageID, eventType string) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var member bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?)`, conversationID, accountID).Scan(&member); err != nil {
		return 0, err
	}
	if !member {
		return 0, ErrNotMember
	}
	var count int
	now := nowString()
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM message_envelopes WHERE id = ? AND conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)`, messageID, conversationID, now).Scan(&count); err != nil {
		return 0, err
	}
	if count == 0 {
		return 0, ErrNotFound
	}
	// Guard against rewinding the read cursor: only advance to a message
	// whose created_at is at or after the currently-recorded one.
	if _, err = tx.ExecContext(ctx, `
		INSERT INTO read_receipts(account_id, conversation_id, message_id, read_at)
		VALUES(?, ?, ?, ?)
		ON CONFLICT(account_id, conversation_id) DO UPDATE SET
			message_id = excluded.message_id,
			read_at = excluded.read_at
		WHERE read_receipts.message_id IS NULL
		   OR (excluded.message_id != read_receipts.message_id
		       AND (SELECT created_at FROM message_envelopes WHERE id = excluded.message_id) >=
		           (SELECT created_at FROM message_envelopes WHERE id = read_receipts.message_id))`,
		accountID, conversationID, messageID, now); err != nil {
		return 0, err
	}
	payload := map[string]string{"account_id": accountID, "message_id": messageID}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, conversationID, payload, now)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return eventID, nil
}

type PushTarget struct {
	ID         string
	Provider   string
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
		SELECT ps.id, ps.provider, ps.endpoint, COALESCE(ps.public_key, ''), COALESCE(ps.auth_secret, '')
		FROM push_subscriptions ps
		JOIN memberships m ON m.account_id = ps.account_id
		WHERE m.conversation_id = ? AND ps.account_id <> ? AND ps.provider IN ('webpush', 'fcm', 'apns') AND ps.disabled_at IS NULL
		  AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ps.account_id AND b.blocked_account_id = ?)
		  AND NOT EXISTS (SELECT 1 FROM conversation_notification_preferences p WHERE p.account_id = ps.account_id AND p.conversation_id = ? AND p.muted = 1)
		ORDER BY ps.id
		LIMIT 500`, conversationID, excludeAccountID, excludeAccountID, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var targets []PushTarget
	for rows.Next() {
		var target PushTarget
		if err := rows.Scan(&target.ID, &target.Provider, &target.Endpoint, &target.PublicKey, &target.AuthSecret); err != nil {
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

const callSelectColumns = `id, conversation_id, created_by, invited_account_id, state, metadata_json, created_at, ended_at, expires_at, version, create_action_id, create_action_hash, last_action_id, last_action_hash`

func (s *Store) CreateCallSession(ctx context.Context, conversationID, accountID string, metadata json.RawMessage) (domain.CallSession, error) {
	call, _, err := s.createCallSession(ctx, conversationID, accountID, metadata, "")
	return call, err
}

func (s *Store) CreateCallSessionWithSyncEvent(ctx context.Context, conversationID, accountID string, metadata json.RawMessage) (domain.CallSession, int64, error) {
	return s.createCallSession(ctx, conversationID, accountID, metadata, "call.signaling")
}

func (s *Store) createCallSession(ctx context.Context, conversationID, accountID string, metadata json.RawMessage, eventType string) (domain.CallSession, int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	defer tx.Rollback()
	var kind string
	var actorMembers, memberCount int
	var invitedAccountID string
	if err := tx.QueryRowContext(ctx, `
		SELECT c.kind,
		       SUM(CASE WHEN a.id = ? THEN 1 ELSE 0 END),
		       COUNT(a.id),
		       COALESCE(MAX(CASE WHEN a.id != ? THEN a.id END), '')
		FROM conversations c
		LEFT JOIN memberships m ON m.conversation_id = c.id
		LEFT JOIN accounts a ON a.id = m.account_id AND a.status = 'active' AND a.deleted_at IS NULL
		WHERE c.id = ?
		GROUP BY c.id, c.kind`, accountID, accountID, conversationID).Scan(&kind, &actorMembers, &memberCount, &invitedAccountID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.CallSession{}, 0, ErrNotMember
		}
		return domain.CallSession{}, 0, err
	}
	if actorMembers == 0 {
		return domain.CallSession{}, 0, ErrNotMember
	}
	if kind != "dm" || memberCount != 2 || invitedAccountID == "" {
		return domain.CallSession{}, 0, ErrInvalidInput
	}
	if len(metadata) == 0 {
		metadata = json.RawMessage(`{}`)
	}
	actionID := callActionID(metadata)
	actionHash := callActionHash(actionID, accountID, "ringing", 0, metadata)
	if actionID != "" {
		existing, err := scanCall(tx.QueryRowContext(ctx, `SELECT `+callSelectColumns+` FROM call_sessions WHERE conversation_id = ? AND created_by = ? AND create_action_id = ?`, conversationID, accountID, actionID))
		if err == nil {
			if existing.CreateActionHash != actionHash {
				return domain.CallSession{}, 0, ErrIdempotencyConflict
			}
			return existing, 0, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return domain.CallSession{}, 0, err
		}
	}
	id, err := domain.NewID("call")
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	createdAt := time.Now().UTC()
	expiresAt := createdAt.Add(2 * time.Minute)
	call := domain.CallSession{ID: id, ConversationID: conversationID, CreatedBy: accountID, InvitedAccountID: invitedAccountID, State: "ringing", Version: 1, Metadata: metadata, CreatedAt: createdAt, ExpiresAt: &expiresAt, CreateActionID: actionID, CreateActionHash: actionHash}
	if _, err = tx.ExecContext(ctx, `INSERT INTO call_sessions(id, conversation_id, created_by, invited_account_id, state, metadata_json, created_at, expires_at, version, create_action_id, create_action_hash) VALUES(?, ?, ?, ?, 'ringing', ?, ?, ?, 1, ?, ?)`, id, conversationID, accountID, invitedAccountID, string(metadata), formatTime(createdAt), formatTime(expiresAt), actionID, actionHash); err != nil {
		return domain.CallSession{}, 0, err
	}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, conversationID, call, formatTime(createdAt))
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return domain.CallSession{}, 0, err
	}
	return call, eventID, nil
}

func (s *Store) ListCallSessions(ctx context.Context, conversationID, accountID string, limit int) ([]domain.CallSession, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	var kind string
	var memberCount int
	if err := s.db.QueryRowContext(ctx, `SELECT c.kind, COUNT(a.id) FROM conversations c JOIN memberships m ON m.conversation_id = c.id JOIN accounts a ON a.id = m.account_id AND a.status = 'active' AND a.deleted_at IS NULL WHERE c.id = ? GROUP BY c.id, c.kind`, conversationID).Scan(&kind, &memberCount); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if kind != "dm" || memberCount != 2 {
		return nil, ErrInvalidInput
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+callSelectColumns+` FROM call_sessions WHERE conversation_id = ? AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = ? AND b.blocked_account_id = call_sessions.created_by) ORDER BY created_at DESC, id DESC LIMIT ?`, conversationID, accountID, limit)
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

func (s *Store) TransitionCallSession(ctx context.Context, callID, accountID string, expectedVersion int64, nextState string, metadata json.RawMessage) (domain.CallSession, error) {
	call, _, err := s.transitionCallSession(ctx, callID, accountID, expectedVersion, nextState, metadata, "")
	return call, err
}

func (s *Store) TransitionCallSessionWithSyncEvent(ctx context.Context, callID, accountID string, expectedVersion int64, nextState string, metadata json.RawMessage) (domain.CallSession, int64, error) {
	return s.transitionCallSession(ctx, callID, accountID, expectedVersion, nextState, metadata, "call.state")
}

func (s *Store) transitionCallSession(ctx context.Context, callID, accountID string, expectedVersion int64, nextState string, metadata json.RawMessage, eventType string) (domain.CallSession, int64, error) {
	if expectedVersion <= 0 {
		return domain.CallSession{}, 0, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	defer tx.Rollback()
	call, err := scanCall(tx.QueryRowContext(ctx, `SELECT `+callSelectColumns+` FROM call_sessions WHERE id = ?`, callID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.CallSession{}, 0, ErrNotFound
	}
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	var kind string
	var memberCount int
	if err := tx.QueryRowContext(ctx, `SELECT c.kind, COUNT(a.id) FROM conversations c LEFT JOIN memberships m ON m.conversation_id = c.id LEFT JOIN accounts a ON a.id = m.account_id AND a.status = 'active' AND a.deleted_at IS NULL WHERE c.id = ? GROUP BY c.id, c.kind`, call.ConversationID).Scan(&kind, &memberCount); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.CallSession{}, 0, ErrNotFound
		}
		return domain.CallSession{}, 0, err
	}
	if kind != "dm" || memberCount != 2 || call.InvitedAccountID == "" {
		return domain.CallSession{}, 0, ErrInvalidInput
	}
	var activeMember bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM memberships m JOIN accounts a ON a.id = m.account_id WHERE m.conversation_id = ? AND m.account_id = ? AND a.status = 'active' AND a.deleted_at IS NULL)`, call.ConversationID, accountID).Scan(&activeMember); err != nil {
		return domain.CallSession{}, 0, err
	}
	if !activeMember {
		return domain.CallSession{}, 0, ErrNotMember
	}
	if accountID != call.CreatedBy && accountID != call.InvitedAccountID {
		var member bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?)`, call.ConversationID, accountID).Scan(&member); err != nil {
			return domain.CallSession{}, 0, err
		}
		if member {
			return domain.CallSession{}, 0, ErrForbidden
		}
		return domain.CallSession{}, 0, ErrNotMember
	}
	actionID := callActionID(metadata)
	actionHash := callActionHash(actionID, accountID, nextState, expectedVersion, metadata)
	if actionID != "" && actionID == call.LastActionID {
		if actionHash != call.LastActionHash {
			return domain.CallSession{}, 0, ErrIdempotencyConflict
		}
		return call, 0, nil
	}
	if expectedVersion != call.Version {
		return domain.CallSession{}, 0, ErrCallVersion
	}
	if nextState == call.State && len(metadata) == 0 {
		return call, 0, nil
	}
	if nextState == call.State && isTerminalCallState(call.State) {
		return domain.CallSession{}, 0, ErrInvalidInput
	}
	allowed := false
	switch {
	case nextState == call.State:
		allowed = true
	case accountID == call.CreatedBy && call.State == "ringing" && nextState == "ended":
		allowed = true
	case accountID == call.CreatedBy && call.State == "active" && nextState == "ended":
		allowed = true
	case accountID == call.InvitedAccountID && call.State == "ringing" && (nextState == "active" || nextState == "rejected" || nextState == "missed"):
		allowed = true
	case accountID == call.InvitedAccountID && call.State == "active" && nextState == "ended":
		allowed = true
	}
	if !allowed {
		return domain.CallSession{}, 0, ErrInvalidInput
	}
	if len(metadata) > 0 {
		call.Metadata = metadata
	}
	now := time.Now().UTC()
	call.State = nextState
	call.Version++
	call.LastActionID = actionID
	call.LastActionHash = actionHash
	terminal := nextState == "rejected" || nextState == "missed" || nextState == "ended"
	if terminal && call.EndedAt == nil {
		call.EndedAt = &now
		expires := now.Add(7 * 24 * time.Hour)
		call.ExpiresAt = &expires
	} else if nextState == "active" {
		expires := now.Add(4 * time.Hour)
		call.ExpiresAt = &expires
	}
	result, err := tx.ExecContext(ctx, `UPDATE call_sessions SET state = ?, metadata_json = ?, ended_at = ?, expires_at = ?, version = ?, last_action_id = ?, last_action_hash = ? WHERE id = ? AND version = ?`, call.State, string(call.Metadata), nullableTime(call.EndedAt), nullableTime(call.ExpiresAt), call.Version, call.LastActionID, call.LastActionHash, call.ID, expectedVersion)
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	if rows != 1 {
		return domain.CallSession{}, 0, ErrCallVersion
	}
	eventID, err := insertOptionalSyncEvent(ctx, tx, eventType, nil, call.ConversationID, call, formatTime(now))
	if err != nil {
		return domain.CallSession{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return domain.CallSession{}, 0, err
	}
	return call, eventID, nil
}

func callActionID(metadata json.RawMessage) string {
	var envelope struct {
		ActionID string `json:"action_id"`
	}
	if json.Unmarshal(metadata, &envelope) != nil {
		return ""
	}
	return envelope.ActionID
}

func callActionHash(actionID, accountID, state string, expectedVersion int64, metadata json.RawMessage) string {
	hash := sha256.New()
	_, _ = hash.Write([]byte(actionID))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write([]byte(accountID))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write([]byte(state))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write([]byte(strconv.FormatInt(expectedVersion, 10)))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write(metadata)
	return hex.EncodeToString(hash.Sum(nil))
}

func isTerminalCallState(state string) bool {
	return state == "rejected" || state == "missed" || state == "ended"
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
		args  []interface{}
	}{
		{`DELETE FROM sessions WHERE token_hash IN (SELECT token_hash FROM sessions WHERE expires_at <= ? ORDER BY expires_at LIMIT 500)`, []interface{}{formatTime(now.UTC())}},
		{`DELETE FROM invites WHERE id IN (SELECT id FROM invites WHERE (expires_at IS NOT NULL AND expires_at < ?) OR (revoked_at IS NOT NULL AND revoked_at < ?) ORDER BY COALESCE(revoked_at, expires_at), id LIMIT 500)`, []interface{}{cutoff, cutoff}},
		{`DELETE FROM device_links WHERE id IN (SELECT id FROM device_links WHERE expires_at < ? AND state IN ('consumed', 'revoked') ORDER BY expires_at, id LIMIT 500)`, []interface{}{cutoff}},
		{`DELETE FROM enrollment_reservations WHERE id IN (SELECT id FROM enrollment_reservations WHERE expires_at < ? OR (consumed_at IS NOT NULL AND consumed_at < ?) ORDER BY COALESCE(consumed_at, expires_at), id LIMIT 500)`, []interface{}{formatTime(now.UTC()), cutoff}},
		{`DELETE FROM push_subscriptions WHERE id IN (SELECT id FROM push_subscriptions WHERE disabled_at IS NOT NULL AND disabled_at < ? ORDER BY disabled_at, id LIMIT 500)`, []interface{}{cutoff}},
		{`DELETE FROM device_key_packages WHERE id IN (SELECT id FROM device_key_packages WHERE expires_at < ? OR (claimed_at IS NOT NULL AND claimed_at < ?) ORDER BY COALESCE(claimed_at, expires_at), id LIMIT 500)`, []interface{}{formatTime(now.UTC()), cutoff}},
	}
	var removed int64
	for _, item := range queries {
		result, err := tx.ExecContext(ctx, item.query, item.args...)
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

func (s *Store) CreateBackupBlob(ctx context.Context, accountID, deviceID, storageKey, ciphertextSHA256 string, sizeBytes int64, keyDerivationMetadata json.RawMessage, recoveryTokenHash []byte) error {
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
	if len(recoveryTokenHash) != 32 {
		return ErrInvalidInput
	}
	var stateCounter int64
	if err := json.Unmarshal(keyDerivationMetadata, &struct {
		StateCounter *int64 `json:"state_counter"`
	}{StateCounter: &stateCounter}); err != nil || stateCounter <= 0 {
		return ErrInvalidInput
	}
	var previousCounter sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(CAST(json_extract(key_derivation_metadata_json, '$.state_counter') AS INTEGER))
		FROM backup_blobs WHERE account_id = ? AND device_id = ?`, accountID, deviceID).Scan(&previousCounter); err != nil {
		return err
	}
	if previousCounter.Valid && stateCounter <= previousCounter.Int64 {
		return ErrInvalidInput
	}
	recoveryExpiresAt := time.Now().UTC().Add(RecoveryCapabilityLifetime)
	if _, err := tx.ExecContext(ctx, `UPDATE backup_blobs SET recovery_token_hash = NULL,
		recovery_expires_at = NULL, recovery_next_offset = 0, recovery_lease_id = NULL,
		recovery_lease_expires_at = NULL WHERE account_id = ? AND device_id = ?`, accountID, deviceID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO backup_blobs(id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at, recovery_token_hash, recovery_expires_at, recovery_next_offset) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)`, id, accountID, nullableEmptyString(deviceID), storageKey, ciphertextSHA256, sizeBytes, string(keyDerivationMetadata), nowString(), recoveryTokenHash, formatTime(recoveryExpiresAt)); err != nil {
		return err
	}
	return tx.Commit()
}

// BeginRecoveryTransfer atomically leases the next contiguous byte range for
// a valid recovery capability. Reusing an earlier range, beginning after a
// gap, or racing an active transfer is rejected.
func (s *Store) BeginRecoveryTransfer(ctx context.Context, recoveryTokenHash []byte, start int64) (RecoveryTransfer, error) {
	if len(recoveryTokenHash) != 32 || start < 0 {
		return RecoveryTransfer{}, ErrRecoveryRange
	}
	leaseID, err := domain.NewID("recovery_lease")
	if err != nil {
		return RecoveryTransfer{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RecoveryTransfer{}, err
	}
	defer tx.Rollback()

	var transfer RecoveryTransfer
	var deviceID sql.NullString
	var metadata, created, recoveryExpiresAt string
	var nextOffset int64
	var lease, leaseExpiresAt sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT id, account_id, device_id, storage_key,
		ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at,
		recovery_expires_at, recovery_next_offset, recovery_lease_id,
		recovery_lease_expires_at FROM backup_blobs
		WHERE recovery_token_hash = ?`, recoveryTokenHash).Scan(
		&transfer.Backup.ID, &transfer.Backup.AccountID, &deviceID,
		&transfer.Backup.StorageKey, &transfer.Backup.CiphertextSHA256,
		&transfer.Backup.SizeBytes, &metadata, &created, &recoveryExpiresAt,
		&nextOffset, &lease, &leaseExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return RecoveryTransfer{}, ErrNotFound
	}
	if err != nil {
		return RecoveryTransfer{}, err
	}
	transfer.Backup.DeviceID = stringPtr(deviceID)
	transfer.Backup.KeyDerivationMetadata = json.RawMessage(metadata)
	transfer.Backup.CreatedAt = parseTime(created)
	expiresAt := parseTime(recoveryExpiresAt)
	now := time.Now().UTC()
	if recoveryExpiresAt == "" || !expiresAt.After(now) {
		return RecoveryTransfer{}, ErrNotFound
	}
	if lease.Valid && parseTime(leaseExpiresAt.String).After(now) {
		return RecoveryTransfer{}, ErrRecoveryBusy
	}
	if start != nextOffset {
		return RecoveryTransfer{}, ErrRecoveryRange
	}
	leaseDeadline := now.Add(RecoveryLeaseLifetime)
	if leaseDeadline.After(expiresAt) {
		leaseDeadline = expiresAt
	}
	result, err := tx.ExecContext(ctx, `UPDATE backup_blobs SET recovery_lease_id = ?,
		recovery_lease_expires_at = ? WHERE id = ? AND recovery_token_hash = ?
		AND recovery_next_offset = ? AND (recovery_lease_id IS NULL OR recovery_lease_expires_at <= ?)`,
		leaseID, formatTime(leaseDeadline), transfer.Backup.ID, recoveryTokenHash,
		nextOffset, formatTime(now))
	if err != nil {
		return RecoveryTransfer{}, err
	}
	if rows, err := result.RowsAffected(); err != nil {
		return RecoveryTransfer{}, err
	} else if rows != 1 {
		return RecoveryTransfer{}, ErrRecoveryBusy
	}
	if err := tx.Commit(); err != nil {
		return RecoveryTransfer{}, err
	}
	transfer.LeaseID = leaseID
	transfer.StartOffset = nextOffset
	return transfer, nil
}

// CompleteRecoveryTransfer advances a leased transfer by the bytes that the
// HTTP writer successfully handed off. A complete final range consumes the
// capability by clearing its hash; an interrupted range keeps it resumable.
func (s *Store) CompleteRecoveryTransfer(ctx context.Context, leaseID string, startOffset, bytesWritten, expected int64) error {
	if leaseID == "" || startOffset < 0 || bytesWritten < 0 || expected < 0 || bytesWritten > expected {
		return ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var id string
	var nextOffset, sizeBytes int64
	now := time.Now().UTC()
	if err := tx.QueryRowContext(ctx, `SELECT id, recovery_next_offset, size_bytes
		FROM backup_blobs WHERE recovery_lease_id = ? AND recovery_next_offset = ?
		AND recovery_lease_expires_at > ?`, leaseID, startOffset, formatTime(now)).Scan(&id, &nextOffset, &sizeBytes); errors.Is(err, sql.ErrNoRows) {
		return ErrRecoveryBusy
	} else if err != nil {
		return err
	}
	if nextOffset > sizeBytes || bytesWritten > sizeBytes-nextOffset {
		return ErrInvalidInput
	}
	newOffset := nextOffset + bytesWritten
	var query string
	var args []interface{}
	if bytesWritten == expected && newOffset == sizeBytes {
		query = `UPDATE backup_blobs SET recovery_token_hash = NULL,
			recovery_next_offset = ?, recovery_lease_id = NULL,
			recovery_lease_expires_at = NULL WHERE recovery_lease_id = ?
			AND recovery_next_offset = ? AND recovery_lease_expires_at > ?`
		args = []interface{}{newOffset, leaseID, startOffset, formatTime(now)}
	} else {
		query = `UPDATE backup_blobs SET recovery_next_offset = ?,
			recovery_lease_id = NULL, recovery_lease_expires_at = NULL
			WHERE recovery_lease_id = ? AND recovery_next_offset = ?
			AND recovery_lease_expires_at > ?`
		args = []interface{}{newOffset, leaseID, startOffset, formatTime(now)}
	}
	result, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return err
	}
	if rows, err := result.RowsAffected(); err != nil {
		return err
	} else if rows != 1 {
		return ErrRecoveryBusy
	}
	return tx.Commit()
}

func (s *Store) BackupForRecoveryToken(ctx context.Context, recoveryTokenHash []byte) (domain.BackupBlob, error) {
	if len(recoveryTokenHash) != 32 {
		return domain.BackupBlob{}, ErrNotFound
	}
	backup, err := scanBackup(s.db.QueryRowContext(ctx, `SELECT id, account_id, device_id, storage_key,
		ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at
		FROM backup_blobs WHERE recovery_token_hash = ? AND recovery_expires_at > ?`, recoveryTokenHash, nowString()))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.BackupBlob{}, ErrNotFound
	}
	return backup, err
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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	defer tx.Rollback()
	backup, err := scanBackup(tx.QueryRowContext(ctx, `SELECT id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at FROM backup_blobs WHERE id = ? AND account_id = ?`, id, accountID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.BackupBlob{}, ErrNotFound
	}
	if err != nil {
		return domain.BackupBlob{}, err
	}
	result, err := tx.ExecContext(ctx, `DELETE FROM backup_blobs WHERE id = ? AND account_id = ?`, id, accountID)
	if err != nil {
		return domain.BackupBlob{}, err
	}
	if rows, _ := result.RowsAffected(); rows == 0 {
		return domain.BackupBlob{}, ErrNotFound
	}
	if err := enqueueBlobDeletion(ctx, tx, backup.StorageKey); err != nil {
		return domain.BackupBlob{}, err
	}
	return backup, tx.Commit()
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
