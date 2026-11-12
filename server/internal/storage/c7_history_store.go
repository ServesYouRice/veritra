package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

// C7 step 3, the routes beside the sealed body (docs/designs/C7-channel-
// history.md, "Server: wire, storage, routes"): the C0 and C2 exceptions for
// group-level messages, the history fetch, former members' signing keys and
// history-hide. All of them answer only while PRIVATE_MESSENGER_C7_HISTORY is
// on; off, the routes are not found and routing is C0's.

// ModerationMessageHidden is the C5 audit kind of a moderator's history-hide.
const ModerationMessageHidden = "message_hidden"

const (
	historyFetchDefaultLimit = 50
	historyFetchMaxLimit     = 100
	formerMemberKeyLimit     = 5000
)

// HistoryBody is one row of the history fetch: what a newcomer needs to open
// and place a pre-join post. References are never served here.
type HistoryBody struct {
	MessageID      string    `json:"message_id"`
	SenderDeviceID string    `json:"sender_device_id"`
	ActionID       string    `json:"action_id"`
	ChannelID      string    `json:"channel_id,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	Epoch          *int64    `json:"epoch,omitempty"`
	Body           []byte    `json:"body"`
}

// FormerMemberKey is the signing key of a device that posted in a
// conversation and is no longer in its group (revoked devices included).
type FormerMemberKey struct {
	DeviceID   string `json:"device_id"`
	AccountID  string `json:"account_id"`
	SigningKey []byte `json:"signing_key"`
	Revoked    bool   `json:"revoked"`
}

// routeCommunityEnvelope is routeEnvelope with C7's exceptions, for
// conversations in the C0 layout while C7 is on:
//
//   - an envelope with no channel keys is group-level (history_sync and
//     history_sync_request), in the shared group and in a private channel's
//     group alike;
//   - a private channel's group carries the channel_id of its own channel
//     (an amendment of C0's "absent everywhere else"), at the layout
//     generation when it names one.
//
// layout reports a conversation in the C0 layout. Legacy channels, groups and
// DMs route as before.
func (s *Store) routeCommunityEnvelope(ctx context.Context, q queryRower, conversationID string, metadata json.RawMessage) (envelopeRoute, bool, error) {
	if !s.c7History {
		route, err := routeEnvelope(ctx, q, conversationID, metadata)
		return route, false, err
	}
	var purpose, communityID string
	var generation int64
	err := q.QueryRowContext(ctx, `SELECT purpose, community_id, generation FROM community_conversation_layouts WHERE conversation_id = ?`, conversationID).Scan(&purpose, &communityID, &generation)
	if errors.Is(err, sql.ErrNoRows) {
		route, err := routeEnvelope(ctx, q, conversationID, metadata)
		return route, false, err
	}
	if err != nil {
		return envelopeRoute{}, false, err
	}
	fields, isObject := metadataFields(metadata)
	if !isObject || metadataRepeatsKey(metadata) {
		return envelopeRoute{}, true, ErrInvalidChannelRoute
	}
	if !metadataHasRouteKeys(fields) {
		return envelopeRoute{shared: purpose == "shared"}, true, nil
	}
	if purpose == "shared" {
		route, err := routeEnvelope(ctx, q, conversationID, metadata)
		return route, true, err
	}
	var channelID string
	if err := json.Unmarshal(fields[EnvelopeChannelKey], &channelID); err != nil || channelID == "" {
		return envelopeRoute{}, true, ErrInvalidChannelRoute
	}
	if raw, ok := fields[EnvelopeLayoutGenerationKey]; ok {
		var claimed int64
		if err := json.Unmarshal(raw, &claimed); err != nil || claimed != generation {
			return envelopeRoute{}, true, ErrInvalidChannelRoute
		}
	}
	var access string
	var routeGeneration int64
	err = q.QueryRowContext(ctx, `SELECT access_mode, generation FROM community_channel_routes WHERE channel_id = ? AND community_id = ? AND conversation_id = ?`, channelID, communityID, conversationID).Scan(&access, &routeGeneration)
	if errors.Is(err, sql.ErrNoRows) {
		return envelopeRoute{}, true, ErrInvalidChannelRoute
	}
	if err != nil {
		return envelopeRoute{}, true, err
	}
	if access != ChannelAccessPrivate || routeGeneration != generation {
		return envelopeRoute{}, true, ErrInvalidChannelRoute
	}
	return envelopeRoute{channelID: channelID, generation: generation}, true, nil
}

// ErrInvalidEpochMetadata answers an envelope whose mls_epoch is present but
// not a non-negative integer.
var ErrInvalidEpochMetadata = errors.New("invalid mls_epoch")

// checkMetadataEpoch refuses an mls_epoch that is not a non-negative int64
// integer literal. The sync join filter (mlsJoinFilterEventFor) reads any
// JSON integer as the epoch, while metadataEpoch and so the history fetch
// read only non-negative ones: a negative epoch would be withheld by sync
// and never served by the history fetch. Refused at write time, both
// readers agree on every stored envelope. An absent epoch stays allowed.
func checkMetadataEpoch(metadata json.RawMessage) error {
	fields, ok := metadataFields(metadata)
	if !ok {
		return nil
	}
	raw, ok := fields["mls_epoch"]
	if !ok {
		return nil
	}
	// A repeated key is read differently by Go (the last value) and by
	// SQLite's json_extract (the first), so {"mls_epoch":-4,"mls_epoch":3}
	// would pass here and be read as -4 by the join filter.
	if metadataRepeatsKey(metadata) {
		return ErrInvalidEpochMetadata
	}
	value, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil || value < 0 {
		return ErrInvalidEpochMetadata
	}
	return nil
}

// ErrEpochOutOfRange answers a C7 envelope whose mls_epoch is below its
// sender device's joined_epoch or above the group's recorded epoch (review
// L1). Honest devices send only in an epoch they are in, which the server
// recorded itself; any other value would steer the I51 join filter and the
// history fetch (a body withheld from members, or served as pre-join).
var ErrEpochOutOfRange = errors.New("mls_epoch out of range")

// checkDeclaredEpochTx applies that range to a C7 envelope (one with a
// sealed body) whose sender device is in the conversation's group roster.
// An absent epoch stays allowed: such a body is never served by the
// history fetch.
func checkDeclaredEpochTx(ctx context.Context, tx *sql.Tx, conversationID, senderDeviceID string, metadata json.RawMessage) error {
	declared := metadataEpoch(metadata)
	if declared == nil {
		return nil
	}
	var joined, current int64
	err := tx.QueryRowContext(ctx, `SELECT jd.joined_epoch, g.epoch FROM conversation_mls_devices jd
		JOIN conversation_mls_groups g ON g.conversation_id = jd.conversation_id
		WHERE jd.conversation_id = ? AND jd.device_id = ? AND jd.removed_after_event_id IS NULL`,
		conversationID, senderDeviceID).Scan(&joined, &current)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if *declared < joined || *declared > current {
		return ErrEpochOutOfRange
	}
	return nil
}

// metadataEpoch is the integer mls_epoch an envelope names, as the I51 join
// filter reads it, or nil.
func metadataEpoch(metadata json.RawMessage) *int64 {
	fields, ok := metadataFields(metadata)
	if !ok {
		return nil
	}
	raw, ok := fields["mls_epoch"]
	if !ok {
		return nil
	}
	var epoch int64
	if err := json.Unmarshal(raw, &epoch); err != nil || epoch < 0 {
		return nil
	}
	return &epoch
}

// currentGroupDevice reports whether deviceID is in conversationID's group
// now, and the device's join cursor and epoch.
func currentGroupDevice(ctx context.Context, q queryRower, conversationID, deviceID string) (bool, error) {
	var one int
	err := q.QueryRowContext(ctx, `SELECT 1 FROM conversation_mls_devices WHERE conversation_id = ? AND device_id = ? AND removed_after_event_id IS NULL`, conversationID, deviceID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// ListHistoryBodies is the history fetch: for the calling device, the bodies
// in conversationID's stream (channelID, or "" for the group-level stream)
// that sync did not give it, newest first, before the message beforeID when
// set. It serves unexpired, undeleted, not history_hidden envelopes from
// senders the caller has not blocked, and the same in every channel and
// mode. Current member devices only.
func (s *Store) ListHistoryBodies(ctx context.Context, accountID, deviceID, conversationID, channelID, beforeID string, limit int) ([]HistoryBody, error) {
	if !s.c7History {
		return nil, ErrNotFound
	}
	if limit <= 0 {
		limit = historyFetchDefaultLimit
	}
	if limit > historyFetchMaxLimit {
		limit = historyFetchMaxLimit
	}
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	community, err := conversationIsCommunity(ctx, s.db, conversationID)
	if err != nil {
		return nil, err
	}
	if !community {
		return nil, ErrNotFound
	}
	inGroup, err := currentGroupDevice(ctx, s.db, conversationID, deviceID)
	if err != nil {
		return nil, err
	}
	if !inGroup {
		return nil, ErrForbidden
	}
	var before int64
	if strings.TrimSpace(beforeID) != "" {
		var cursor sql.NullInt64
		err := s.db.QueryRowContext(ctx, `SELECT sync_event_id FROM envelope_bodies WHERE message_id = ? AND conversation_id = ?`, beforeID, conversationID).Scan(&cursor)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && !cursor.Valid) {
			return nil, ErrInvalidInput
		}
		if err != nil {
			return nil, err
		}
		before = cursor.Int64
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT me.id, me.sender_device_id, me.idempotency_key, COALESCE(b.channel_id, ''), me.created_at, b.mls_epoch, b.body
		FROM envelope_bodies b
		JOIN message_envelopes me ON me.id = b.message_id
		JOIN conversation_mls_devices jd ON jd.conversation_id = b.conversation_id AND jd.device_id = ?1 AND jd.removed_after_event_id IS NULL
		WHERE b.conversation_id = ?2
		  AND ((?3 = '' AND b.channel_id IS NULL) OR b.channel_id = ?3)
		  AND b.sync_event_id IS NOT NULL
		  AND (?4 = 0 OR b.sync_event_id < ?4)
		  AND b.history_hidden = 0
		  AND me.deleted_at IS NULL
		  AND (me.expires_at IS NULL OR me.expires_at > ?5)
		  AND NOT EXISTS (SELECT 1 FROM account_blocks bl WHERE bl.blocker_account_id = ?6 AND bl.blocked_account_id = me.sender_account_id)
		  AND (b.sync_event_id <= jd.joined_after_event_id
		       OR (b.mls_epoch IS NOT NULL AND b.mls_epoch < jd.joined_epoch))
		ORDER BY b.sync_event_id DESC
		LIMIT ?7`, deviceID, conversationID, strings.TrimSpace(channelID), before, nowString(), accountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	bodies := []HistoryBody{}
	for rows.Next() {
		var row HistoryBody
		var created string
		var epoch sql.NullInt64
		if err := rows.Scan(&row.MessageID, &row.SenderDeviceID, &row.ActionID, &row.ChannelID, &created, &epoch, &row.Body); err != nil {
			return nil, err
		}
		row.CreatedAt = parseTime(created)
		if epoch.Valid {
			value := epoch.Int64
			row.Epoch = &value
		}
		bodies = append(bodies, row)
	}
	return bodies, rows.Err()
}

// ListFormerMemberKeys is the bulk call a device makes at join: the signing
// key of every device that posted in conversationID and is no longer in its
// group, revoked devices included. A deleted account's keys are nulled
// (account_store.go) and so absent. Current member devices only, the same
// call in every mode.
func (s *Store) ListFormerMemberKeys(ctx context.Context, accountID, deviceID, conversationID string) ([]FormerMemberKey, error) {
	if !s.c7History {
		return nil, ErrNotFound
	}
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	community, err := conversationIsCommunity(ctx, s.db, conversationID)
	if err != nil {
		return nil, err
	}
	if !community {
		return nil, ErrNotFound
	}
	inGroup, err := currentGroupDevice(ctx, s.db, conversationID, deviceID)
	if err != nil {
		return nil, err
	}
	if !inGroup {
		return nil, ErrForbidden
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT d.id, d.account_id, d.signing_key, d.revoked_at IS NOT NULL
		FROM devices d
		WHERE d.signing_key IS NOT NULL
		  AND EXISTS (SELECT 1 FROM message_envelopes me WHERE me.conversation_id = ?1 AND me.sender_device_id = d.id)
		  AND NOT EXISTS (SELECT 1 FROM conversation_mls_devices jd
		    WHERE jd.conversation_id = ?1 AND jd.device_id = d.id AND jd.removed_after_event_id IS NULL)
		ORDER BY d.id
		LIMIT ?2`, conversationID, formerMemberKeyLimit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	keys := []FormerMemberKey{}
	for rows.Next() {
		var key FormerMemberKey
		if err := rows.Scan(&key.DeviceID, &key.AccountID, &key.SigningKey, &key.Revoked); err != nil {
			return nil, err
		}
		keys = append(keys, key)
	}
	return keys, rows.Err()
}

// HideHistoryMessage marks a community envelope history_hidden: the history
// fetch never serves it again, while sync keeps serving the envelope and its
// body until retention removes them. Allowed for the envelope's sender
// account, or for a member whose built-in role in that conversation may
// delete the sender's messages (C5's rule); a moderator's hide gets an
// id-and-kind audit row. Repeating it is a no-op. Returns the conversation.
func (s *Store) HideHistoryMessage(ctx context.Context, messageID, accountID string) (string, error) {
	if !s.c7History {
		return "", ErrNotFound
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var conversationID, senderAccountID string
	var channelID sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT me.conversation_id, me.sender_account_id, b.channel_id
		FROM message_envelopes me JOIN envelope_bodies b ON b.message_id = me.id
		WHERE me.id = ?`, messageID).Scan(&conversationID, &senderAccountID, &channelID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	var actorRole string
	err = tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID).Scan(&actorRole)
	if errors.Is(err, sql.ErrNoRows) {
		// Not a member: indistinguishable from a missing message.
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	moderator := accountID != senderAccountID
	if moderator {
		senderRole := domain.RoleMember
		var role string
		err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, senderAccountID).Scan(&role)
		if err == nil {
			senderRole = role
		} else if !errors.Is(err, sql.ErrNoRows) {
			return "", err
		}
		if !domain.CanDeleteOthersMessage(actorRole, senderRole) {
			return "", ErrForbidden
		}
	}
	result, err := tx.ExecContext(ctx, `UPDATE envelope_bodies SET history_hidden = 1 WHERE message_id = ? AND history_hidden = 0`, messageID)
	if err != nil {
		return "", err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return "", err
	}
	if moderator && changed > 0 {
		var communityID sql.NullString
		if err := tx.QueryRowContext(ctx, `SELECT COALESCE(c.community_id, l.community_id)
			FROM conversations c LEFT JOIN community_conversation_layouts l ON l.conversation_id = c.id
			WHERE c.id = ?`, conversationID).Scan(&communityID); err != nil {
			return "", err
		}
		if communityID.Valid {
			if err := appendModerationEventTx(ctx, tx, communityID.String, accountID, senderAccountID, channelID.String, ModerationMessageHidden); err != nil {
				return "", err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return conversationID, nil
}
