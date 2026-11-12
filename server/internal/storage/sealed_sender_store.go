package storage

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/sealedsender"
)

// L2-3 sealed sender (D122; docs/crypto.md, "Sealed sender with VOPRF
// tokens"). Issuance is per account and rate-limited; redemption names no
// account or device, and nothing stored here links a spent token to the
// account it was issued to.

var (
	// ErrSealedNotEligible: the conversation takes identified posts only
	// (a community conversation, admins-only posting, or a member under a
	// timeout).
	ErrSealedNotEligible = errors.New("conversation does not take sealed posts")
	// ErrSealedGenerationChanged: the token names an older generation (a
	// member left or a device was revoked since it was issued).
	ErrSealedGenerationChanged = errors.New("sealed token generation changed")
	// ErrSealedTokenLimit: the account's daily cap for the conversation.
	ErrSealedTokenLimit = errors.New("sealed token limit reached")
	// ErrSealedTokenSpent: the nonce paid for another post already.
	ErrSealedTokenSpent = errors.New("sealed token already spent")
	// ErrSealedTokenInvalid: the token does not open this conversation.
	ErrSealedTokenInvalid = errors.New("sealed token invalid")
)

// SealedConversationState is what the issuance route tells a member.
type SealedConversationState struct {
	Generation uint64
	Eligible   bool
	// Issued is the number of tokens the account was given for the
	// conversation and epoch.
	Issued int
}

// SealedSenderKey returns the instance's POPRF key, making it on first use.
func (s *Store) SealedSenderKey(ctx context.Context) (*sealedsender.Key, error) {
	var private []byte
	err := s.db.QueryRowContext(ctx, `SELECT private_key FROM sealed_sender_keys WHERE id = 1`).Scan(&private)
	if errors.Is(err, sql.ErrNoRows) {
		fresh, err := sealedsender.GenerateKey(nil)
		if err != nil {
			return nil, err
		}
		key, err := sealedsender.LoadKey(fresh)
		if err != nil {
			return nil, err
		}
		// Two first uses race: the first insert wins and both read it back.
		if _, err := s.db.ExecContext(ctx, `INSERT INTO sealed_sender_keys(id, key_id, private_key, public_key, created_at) VALUES(1, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING`,
			key.ID(), fresh, key.PublicKey(), nowString()); err != nil {
			return nil, err
		}
		err = s.db.QueryRowContext(ctx, `SELECT private_key FROM sealed_sender_keys WHERE id = 1`).Scan(&private)
		if err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	return sealedsender.LoadKey(private)
}

type sealedQuerier interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}

// sealedGeneration returns the conversation's token generation (0 when no
// member has left yet).
func sealedGeneration(ctx context.Context, q sealedQuerier, conversationID string) (uint64, error) {
	var generation int64
	err := q.QueryRowContext(ctx, `SELECT generation FROM sealed_conversation_state WHERE conversation_id = ?`, conversationID).Scan(&generation)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return uint64(generation), nil
}

// sealedEligible reports whether the conversation takes sealed posts:
// a DM or group outside any community, posting open to everyone, and no
// member under a C5 timeout now. ErrNotFound for a missing conversation.
func sealedEligible(ctx context.Context, q sealedQuerier, conversationID string, now time.Time) (bool, error) {
	var eligible bool
	err := q.QueryRowContext(ctx, `
		SELECT c.kind IN ('dm', 'group') AND c.community_id IS NULL AND c.channel_id IS NULL
		       AND c.posting_policy = 'everyone'
		       AND NOT EXISTS (SELECT 1 FROM memberships m WHERE m.conversation_id = c.id
		                       AND m.timeout_until IS NOT NULL AND m.timeout_until > ?)
		FROM conversations c WHERE c.id = ?`, formatTime(now), conversationID).Scan(&eligible)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	return eligible, err
}

// sealedMembersCapable reports whether every live device of every member of
// the conversation reads sealed events (sealed_capable_devices). Issuance
// needs it; redemption does not, so a device linked after tokens were issued
// does not turn a sender's queued post into a failure (that device misses
// the post instead, docs/crypto.md "As built").
func sealedMembersCapable(ctx context.Context, q sealedQuerier, conversationID string) (bool, error) {
	var capable bool
	err := q.QueryRowContext(ctx, `
		SELECT NOT EXISTS (
		  SELECT 1 FROM memberships m JOIN devices d ON d.account_id = m.account_id
		  WHERE m.conversation_id = ? AND d.revoked_at IS NULL
		    AND NOT EXISTS (SELECT 1 FROM sealed_capable_devices c WHERE c.device_id = d.id))`, conversationID).Scan(&capable)
	return capable, err
}

// NoteSealedCapableDevice records that the device's app reads sealed
// events. Idempotent.
func (s *Store) NoteSealedCapableDevice(ctx context.Context, deviceID string) error {
	if deviceID == "" {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO sealed_capable_devices(device_id, noted_at)
		SELECT id, ? FROM devices WHERE id = ? AND revoked_at IS NULL
		ON CONFLICT(device_id) DO NOTHING`, nowString(), deviceID)
	return err
}

// SealedConversationForAccount returns the generation, eligibility and the
// tokens already issued for epoch, to a member only (ErrNotFound otherwise,
// so the route cannot probe conversation ids).
func (s *Store) SealedConversationForAccount(ctx context.Context, conversationID, accountID string, epoch uint32) (SealedConversationState, error) {
	if err := s.requireConversationMember(ctx, conversationID, accountID); err != nil {
		return SealedConversationState{}, err
	}
	eligible, err := sealedEligible(ctx, s.db, conversationID, time.Now().UTC())
	if err != nil {
		return SealedConversationState{}, err
	}
	if eligible {
		if eligible, err = sealedMembersCapable(ctx, s.db, conversationID); err != nil {
			return SealedConversationState{}, err
		}
	}
	generation, err := sealedGeneration(ctx, s.db, conversationID)
	if err != nil {
		return SealedConversationState{}, err
	}
	var issued int
	err = s.db.QueryRowContext(ctx, `SELECT issued FROM sealed_token_issuance WHERE account_id = ? AND conversation_id = ? AND epoch = ?`, accountID, conversationID, int64(epoch)).Scan(&issued)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return SealedConversationState{}, err
	}
	return SealedConversationState{Generation: generation, Eligible: eligible, Issued: issued}, nil
}

func (s *Store) requireConversationMember(ctx context.Context, conversationID, accountID string) error {
	var one int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

// ReserveSealedTokens charges count tokens for (account, conversation,
// epoch) against limit, after checking membership (ErrNotFound),
// eligibility and the generation. The caller evaluates the blinded nonces
// only after this commits; a failed evaluation leaves the charge, which
// costs the caller nothing but its own budget.
func (s *Store) ReserveSealedTokens(ctx context.Context, conversationID, accountID string, epoch uint32, generation uint64, count, limit int) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var one int
	if err := tx.QueryRowContext(ctx, `SELECT 1 FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID).Scan(&one); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	eligible, err := sealedEligible(ctx, tx, conversationID, time.Now().UTC())
	if err != nil {
		return err
	}
	if eligible {
		if eligible, err = sealedMembersCapable(ctx, tx, conversationID); err != nil {
			return err
		}
	}
	if !eligible {
		return ErrSealedNotEligible
	}
	current, err := sealedGeneration(ctx, tx, conversationID)
	if err != nil {
		return err
	}
	if current != generation {
		return ErrSealedGenerationChanged
	}
	var issued int
	err = tx.QueryRowContext(ctx, `SELECT issued FROM sealed_token_issuance WHERE account_id = ? AND conversation_id = ? AND epoch = ?`, accountID, conversationID, int64(epoch)).Scan(&issued)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if issued+count > limit {
		return ErrSealedTokenLimit
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO sealed_token_issuance(account_id, conversation_id, epoch, issued) VALUES(?, ?, ?, ?)
		ON CONFLICT(account_id, conversation_id, epoch) DO UPDATE SET issued = issued + excluded.issued`,
		accountID, conversationID, int64(epoch), count); err != nil {
		return err
	}
	return tx.Commit()
}

// SealedGeneration returns the conversation's current token generation.
func (s *Store) SealedGeneration(ctx context.Context, conversationID string) (uint64, error) {
	return sealedGeneration(ctx, s.db, conversationID)
}

// SaveSealedEnvelope stores a sealed post the caller has already checked
// the token of (output, key and epoch), spends the token and writes the
// sync event and push wakes, in one transaction. It returns the stored
// envelope, whether it was an idempotent retry, the sync event id and every
// member account (the sender is unknown, so none is left out).
//
// Order: the conversation must exist (else ErrSealedTokenInvalid, as an
// unknown id); a stored post under the same idempotency key answers as a
// retry when it is the same post (without spending this token, whatever its
// generation, and even if the conversation is no longer eligible) and as a
// conflict otherwise; then the conversation must be eligible, the
// generation still the token's, and the nonce is spent (ErrSealedTokenSpent
// on reuse).
func (s *Store) SaveSealedEnvelope(ctx context.Context, envelope domain.SealedMessageEnvelope, token domain.SealedToken) (domain.SealedMessageEnvelope, bool, int64, []string, error) {
	if len(envelope.CryptoMetadata) == 0 {
		envelope.CryptoMetadata = json.RawMessage(`{}`)
	}
	if err := checkMetadataEpoch(envelope.CryptoMetadata); err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	defer tx.Rollback()
	now := time.Now().UTC()
	eligible, err := sealedEligible(ctx, tx, envelope.ConversationID, now)
	if errors.Is(err, ErrNotFound) {
		return domain.SealedMessageEnvelope{}, false, 0, nil, ErrSealedTokenInvalid
	}
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	// The retry of a stored post comes before eligibility and the
	// generation: once a sealed attempt may have landed the app never posts
	// that message identified (it would be stored twice), so a retry must
	// still answer 200 after the conversation became admins-only or a
	// member left. The token was already checked for this conversation.
	existing, err := scanSealedEnvelope(tx.QueryRowContext(ctx, `SELECT `+sealedEnvelopeColumns+` FROM sealed_message_envelopes WHERE conversation_id = ? AND idempotency_key = ?`, envelope.ConversationID, envelope.IdempotencyKey))
	if err == nil {
		if existing.ExpiresAt == nil || existing.ExpiresAt.After(now) {
			if !sameSealedPost(existing, envelope) {
				return domain.SealedMessageEnvelope{}, false, 0, nil, ErrIdempotencyConflict
			}
			if err := tx.Commit(); err != nil {
				return domain.SealedMessageEnvelope{}, false, 0, nil, err
			}
			return existing, true, 0, nil, nil
		}
		// An expired post frees its key, as for identified envelopes.
		if err := deleteSealedEnvelopesTx(ctx, tx, []string{existing.ID}); err != nil {
			return domain.SealedMessageEnvelope{}, false, 0, nil, err
		}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	// Review H1: a sealed post may not take the idempotency key of an
	// identified envelope in the same conversation. Every member reads that
	// key, and the sending device would take a sealed post under it for its
	// own. Before eligibility, so sealed_not_eligible proves that no envelope
	// of either kind is stored under (conversation, key).
	var taken int
	err = tx.QueryRowContext(ctx, `SELECT 1 FROM message_envelopes WHERE idempotency_key = ? AND conversation_id = ? LIMIT 1`, envelope.IdempotencyKey, envelope.ConversationID).Scan(&taken)
	if err == nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, ErrIdempotencyConflict
	} else if !errors.Is(err, sql.ErrNoRows) {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	if !eligible {
		return domain.SealedMessageEnvelope{}, false, 0, nil, ErrSealedNotEligible
	}
	generation, err := sealedGeneration(ctx, tx, envelope.ConversationID)
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	if generation != token.Generation {
		return domain.SealedMessageEnvelope{}, false, 0, nil, ErrSealedGenerationChanged
	}
	envelope.ID, err = domain.NewID("sealed")
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	result, err := tx.ExecContext(ctx, `INSERT INTO sealed_spent_tokens(key_id, epoch, nonce, message_id) VALUES(?, ?, ?, ?) ON CONFLICT DO NOTHING`,
		token.KeyID, int64(token.Epoch), token.Nonce, envelope.ID)
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	if spent, err := result.RowsAffected(); err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	} else if spent == 0 {
		return domain.SealedMessageEnvelope{}, false, 0, nil, ErrSealedTokenSpent
	}
	envelope.Sealed = true
	envelope.CreatedAt = now
	var retention sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT retention_seconds FROM conversations WHERE id = ?`, envelope.ConversationID).Scan(&retention); err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	if retention.Valid {
		retentionExpiresAt := now.Add(time.Duration(retention.Int64) * time.Second)
		if envelope.ExpiresAt == nil || envelope.ExpiresAt.After(retentionExpiresAt) {
			envelope.ExpiresAt = &retentionExpiresAt
		}
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO sealed_message_envelopes(id, conversation_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, frank_commit, created_at, expires_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		envelope.ID, envelope.ConversationID, envelope.IdempotencyKey, envelope.Ciphertext, envelope.CryptoProtocol,
		string(envelope.CryptoMetadata), nullableBytes(envelope.FrankCommit), formatTime(now), nullableTime(envelope.ExpiresAt)); err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	payload, err := json.Marshal(sealedSyncEventPayload(envelope))
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	inserted, err := tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('`+SealedMessageEventType+`', NULL, ?, ?, ?)`, envelope.ConversationID, string(payload), formatTime(now))
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	eventID, err := inserted.LastInsertId()
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	wakeExpiresAt := now.Add(pushWakeJobTTL)
	if envelope.ExpiresAt != nil && envelope.ExpiresAt.Before(wakeExpiresAt) {
		wakeExpiresAt = envelope.ExpiresAt.UTC()
	}
	if err := enqueueSealedPushWakeJobs(ctx, tx, eventID, envelope.ConversationID, formatTime(now), formatTime(wakeExpiresAt)); err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	recipients, err := memberAccountIDsTx(ctx, tx, envelope.ConversationID)
	if err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	if err := tx.Commit(); err != nil {
		return domain.SealedMessageEnvelope{}, false, 0, nil, err
	}
	return envelope, false, eventID, recipients, nil
}

// SealedMessageEventType is the sync and realtime event of a sealed post.
const SealedMessageEventType = "message.sealed.created"

func sealedSyncEventPayload(envelope domain.SealedMessageEnvelope) map[string]interface{} {
	return map[string]interface{}{
		"message_id":      envelope.ID,
		"conversation_id": envelope.ConversationID,
		"sealed":          true,
		"envelope":        envelope,
	}
}

func sameSealedPost(existing, requested domain.SealedMessageEnvelope) bool {
	return existing.ConversationID == requested.ConversationID &&
		existing.CryptoProtocol == requested.CryptoProtocol &&
		bytes.Equal(existing.Ciphertext, requested.Ciphertext) &&
		bytes.Equal(existing.CryptoMetadata, requested.CryptoMetadata) &&
		bytes.Equal(existing.FrankCommit, requested.FrankCommit)
}

func memberAccountIDsTx(ctx context.Context, tx *sql.Tx, conversationID string) ([]string, error) {
	rows, err := tx.QueryContext(ctx, `SELECT account_id FROM memberships WHERE conversation_id = ? ORDER BY account_id`, conversationID)
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

// enqueueSealedPushWakeJobs wakes every member's devices: the sender is
// unknown, so its own account is woken too and no block can apply (the
// receiving app hides blocked senders after decrypting). push_wake_jobs
// requires a sender account; the recipient stands in, which makes the
// block filter in ClaimPushWakeJobs a no-op for these rows.
func enqueueSealedPushWakeJobs(ctx context.Context, tx *sql.Tx, eventID int64, conversationID, createdAt, expiresAt string) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO push_wake_jobs(sync_event_id, conversation_id, sender_account_id, recipient_account_id, subscription_id, created_at, next_attempt_at, expires_at)
		SELECT ?, ?, ps.account_id, ps.account_id, ps.id, ?, ?, ?
		FROM push_subscriptions ps
		JOIN memberships m ON m.account_id = ps.account_id
		LEFT JOIN devices d ON d.id = ps.device_id AND d.account_id = ps.account_id
		WHERE m.conversation_id = ?
		  AND ps.provider IN ('webpush', 'fcm', 'apns', 'unifiedpush')
		  AND ps.disabled_at IS NULL
		  AND (ps.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))
		  AND (ps.notification_mode='local_decrypt_v1' OR NOT EXISTS (
			SELECT 1 FROM conversation_notification_preferences p
			WHERE p.account_id = ps.account_id AND p.conversation_id = ? AND p.muted = 1 AND (p.muted_until IS NULL OR p.muted_until > CAST(strftime('%s', 'now') AS INTEGER))
		  ))
		ON CONFLICT(sync_event_id, recipient_account_id, subscription_id) DO NOTHING`,
		eventID, conversationID, createdAt, createdAt, expiresAt, conversationID, conversationID)
	return err
}

const sealedEnvelopeColumns = `id, conversation_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, frank_commit, created_at, expires_at`

func scanSealedEnvelope(row interface{ Scan(...interface{}) error }) (domain.SealedMessageEnvelope, error) {
	var envelope domain.SealedMessageEnvelope
	var metadata, created string
	var expires sql.NullString
	if err := row.Scan(&envelope.ID, &envelope.ConversationID, &envelope.IdempotencyKey, &envelope.Ciphertext, &envelope.CryptoProtocol, &metadata, &envelope.FrankCommit, &created, &expires); err != nil {
		return domain.SealedMessageEnvelope{}, err
	}
	envelope.CryptoMetadata = json.RawMessage(metadata)
	envelope.Sealed = true
	envelope.CreatedAt = parseTime(created)
	if expires.Valid {
		t := parseTime(expires.String)
		envelope.ExpiresAt = &t
	}
	return envelope, nil
}

// SealedMessageForAccount returns one sealed envelope to a current member
// of its conversation (ErrNotFound otherwise, as for MessageForAccount), or
// ErrMessageExpired once it has expired (the I33 proof).
func (s *Store) SealedMessageForAccount(ctx context.Context, messageID, accountID string) (domain.SealedMessageEnvelope, error) {
	envelope, err := scanSealedEnvelope(s.db.QueryRowContext(ctx, `
		SELECT se.id, se.conversation_id, se.idempotency_key, se.ciphertext, se.crypto_protocol,
		       se.crypto_metadata_json, se.frank_commit, se.created_at, se.expires_at
		FROM sealed_message_envelopes se
		JOIN memberships m ON m.conversation_id = se.conversation_id AND m.account_id = ?
		WHERE se.id = ?`, accountID, messageID))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.SealedMessageEnvelope{}, ErrNotFound
	}
	if err != nil {
		return domain.SealedMessageEnvelope{}, err
	}
	if envelope.ExpiresAt != nil && !envelope.ExpiresAt.After(time.Now().UTC()) {
		return domain.SealedMessageEnvelope{}, ErrMessageExpired
	}
	return envelope, nil
}

// redactSealedSyncEventsSQL cuts a sealed post's sync event down to its
// ids, as redactMessageSyncEventsSQL does for identified ones.
const redactSealedSyncEventsSQL = `UPDATE sync_events SET payload_json = json_object(
	'message_id', json_extract(payload_json, '$.message_id'),
	'conversation_id', COALESCE(json_extract(payload_json, '$.conversation_id'), conversation_id),
	'sealed', 1,
	'redacted', 1)`

// deleteSealedEnvelopesTx deletes sealed envelopes and redacts the
// ciphertext out of their sync events.
func deleteSealedEnvelopesTx(ctx context.Context, tx *sql.Tx, ids []string) error {
	for _, id := range ids {
		if _, err := tx.ExecContext(ctx, redactSealedSyncEventsSQL+`
			WHERE conversation_id = (SELECT conversation_id FROM sealed_message_envelopes WHERE id = ?1)
			  AND event_type = '`+SealedMessageEventType+`'
			  AND json_extract(payload_json, '$.message_id') = ?1
			  AND json_extract(payload_json, '$.envelope') IS NOT NULL`, id); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM sealed_message_envelopes WHERE id = ?`, id); err != nil {
			return err
		}
	}
	return nil
}

// pruneSealedTx removes a bounded page of expired sealed envelopes (with
// their sync event copies) and the spent tokens and issuance counts of
// epochs that can no longer be redeemed or issued. It returns the number
// of envelopes removed.
func pruneSealedTx(ctx context.Context, tx *sql.Tx, now time.Time) (int64, error) {
	rows, err := tx.QueryContext(ctx, `SELECT id FROM sealed_message_envelopes WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at, id LIMIT 500`, formatTime(now))
	if err != nil {
		return 0, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	if err := deleteSealedEnvelopesTx(ctx, tx, ids); err != nil {
		return 0, err
	}
	today := int64(sealedsender.Epoch(now))
	// Redeemable: yesterday and today. Issued: today and tomorrow, so a
	// count for yesterday no longer caps anything.
	if _, err := tx.ExecContext(ctx, `DELETE FROM sealed_spent_tokens WHERE epoch < ?`, today-1); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sealed_token_issuance WHERE epoch < ?`, today); err != nil {
		return 0, err
	}
	return int64(len(ids)), nil
}
