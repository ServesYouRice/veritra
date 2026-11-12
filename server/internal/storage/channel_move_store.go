package storage

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"private-messenger/server/internal/domain"
)

// C3 channel conversion (C7 decision 11; docs/crypto.md, "C3 channel
// conversion"). A routed channel moves between the community's shared
// conversation and a private conversation of its own. The server re-routes
// it and keeps a c3_channel_moves row; the apps carry the history in MLS
// (the move record and its wrap), and members of the destination's group
// read the old conversation's bodies up to the move through the routes
// below. The server learns what it already knew: it routes the channel.

// ChannelMovedEventType is the stored event, ids only, that tells the
// members of both conversations that a channel moved.
const ChannelMovedEventType = "conversation.channel_moved"

// ChannelMove is a committed move.
type ChannelMove struct {
	ChannelID          string `json:"channel_id"`
	CommunityID        string `json:"community_id"`
	FromConversationID string `json:"from_conversation_id"`
	ToConversationID   string `json:"to_conversation_id"`
	FromAccess         string `json:"from_access"`
	ToAccess           string `json:"to_access"`
	// LayoutGeneration is the destination route's generation.
	LayoutGeneration int64 `json:"layout_generation"`
	// MovedBy is the account that moved the channel (review L-6: its own
	// device, having lost the answer, finishes the conversion from the
	// event).
	MovedBy string `json:"moved_by"`
}

// ChannelMoveResult is a move and what the handler publishes after it.
type ChannelMoveResult struct {
	Move         ChannelMove
	Conversation domain.Conversation
	// FromEventID and ToEventID are the stored events of each conversation.
	FromEventID int64
	ToEventID   int64
	// Replayed is set when the request repeated the actor's own latest
	// move (review L-6): the answer is that move, nothing is stored and no
	// event is published.
	Replayed bool
}

// MoveChannel moves channelID to access ("open", "announcement" or
// "private") for actorAccountID, an owner or admin of the community.
// Open or announcement to private makes a new private conversation whose
// only member is the actor, as creating a private channel does; private to
// open or announcement routes the channel to the shared conversation. The
// old conversation stays; the route refuses new posts in the channel there.
//
// Review L-8: "open" for a private channel that was an announcement
// channel before it went private restores "announcement", so a round trip
// keeps admins-only posting; "announcement" is always taken as asked.
//
// Review L-6: a request that repeats the actor's own latest move of the
// channel (the channel is still where that move put it, in the same access
// class) answers that move again (Replayed): a lost answer and a retry
// must not end in a refusal with nothing to follow up.
func (s *Store) MoveChannel(ctx context.Context, channelID, access, actorAccountID string) (ChannelMoveResult, error) {
	if access != ChannelAccessOpen && access != ChannelAccessAnnouncement && access != ChannelAccessPrivate {
		return ChannelMoveResult{}, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ChannelMoveResult{}, err
	}
	defer tx.Rollback()
	var move ChannelMove
	move.ChannelID = channelID
	move.ToAccess = access
	err = tx.QueryRowContext(ctx, `SELECT community_id, conversation_id, access_mode FROM community_channel_routes WHERE channel_id = ?`, channelID).
		Scan(&move.CommunityID, &move.FromConversationID, &move.FromAccess)
	if errors.Is(err, sql.ErrNoRows) {
		return ChannelMoveResult{}, ErrNotFound
	}
	if err != nil {
		return ChannelMoveResult{}, err
	}
	var actorRole string
	err = tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, move.CommunityID, actorAccountID).Scan(&actorRole)
	if errors.Is(err, sql.ErrNoRows) {
		return ChannelMoveResult{}, ErrNotMember
	}
	if err != nil {
		return ChannelMoveResult{}, err
	}
	if !domain.CanCreateChannels(actorRole) {
		return ChannelMoveResult{}, ErrForbidden
	}
	// Open and announcement share the shared group: between them is a
	// posting setting, not a move.
	if (move.FromAccess == ChannelAccessPrivate) == (access == ChannelAccessPrivate) {
		result, replay, err := replayedMove(ctx, tx, channelID, move.FromConversationID, access, actorAccountID)
		if err != nil {
			return ChannelMoveResult{}, err
		}
		if !replay {
			return ChannelMoveResult{}, ErrInvalidInput
		}
		if err := tx.Commit(); err != nil {
			return ChannelMoveResult{}, err
		}
		return result, nil
	}
	if move.FromAccess == ChannelAccessPrivate && access == ChannelAccessOpen {
		// Review L-8: the posting mode the channel had before it went private.
		var before sql.NullString
		if err := tx.QueryRowContext(ctx, `SELECT from_access FROM c3_channel_moves WHERE channel_id = ? AND to_conversation_id = ? ORDER BY id DESC LIMIT 1`,
			channelID, move.FromConversationID).Scan(&before); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return ChannelMoveResult{}, err
		}
		if before.Valid && before.String == ChannelAccessAnnouncement {
			access = ChannelAccessAnnouncement
			move.ToAccess = access
		}
	}
	layout, err := communityLayoutOf(ctx, tx, move.CommunityID)
	if err != nil {
		return ChannelMoveResult{}, err
	}
	if !layout.active {
		return ChannelMoveResult{}, ErrNotFound
	}
	now := nowString()
	move.LayoutGeneration = layout.generation
	legacyKind := "private"
	if access == ChannelAccessAnnouncement {
		legacyKind = "announcement"
	}
	if access == ChannelAccessPrivate {
		if move.ToConversationID, err = domain.NewID("conv"); err != nil {
			return ChannelMoveResult{}, err
		}
		if err := s.checkOwnConversations(ctx, tx, actorAccountID, 1); err != nil {
			return ChannelMoveResult{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, created_at) VALUES(?, 'community_channel', NULL, ?, ?, ?, ?)`, move.ToConversationID, move.CommunityID, channelID, actorAccountID, now); err != nil {
			return ChannelMoveResult{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO community_conversation_layouts(conversation_id, community_id, purpose, generation) VALUES(?, ?, 'private', ?)`, move.ToConversationID, move.CommunityID, layout.generation); err != nil {
			return ChannelMoveResult{}, err
		}
		if err := insertConversationMember(ctx, tx, move.ToConversationID, actorAccountID, actorRole, move.CommunityID, now); err != nil {
			return ChannelMoveResult{}, err
		}
	} else {
		move.ToConversationID = layout.sharedConversationID
	}
	if _, err := tx.ExecContext(ctx, `UPDATE community_channel_routes SET conversation_id = ?, access_mode = ?, generation = ? WHERE channel_id = ?`, move.ToConversationID, access, layout.generation, channelID); err != nil {
		return ChannelMoveResult{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE channels SET kind = ? WHERE id = ?`, legacyKind, channelID); err != nil {
		return ChannelMoveResult{}, err
	}
	var cutoff int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM sync_events`).Scan(&cutoff); err != nil {
		return ChannelMoveResult{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO c3_channel_moves(channel_id, community_id, from_conversation_id, to_conversation_id, from_access, to_access, cutoff_event_id, moved_by, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		channelID, move.CommunityID, move.FromConversationID, move.ToConversationID, move.FromAccess, access, cutoff, actorAccountID, now); err != nil {
		return ChannelMoveResult{}, err
	}
	move.MovedBy = actorAccountID
	payload := map[string]interface{}{
		"channel_id":           channelID,
		"from_conversation_id": move.FromConversationID,
		"to_conversation_id":   move.ToConversationID,
		"access_mode":          access,
		"moved_by":             actorAccountID,
	}
	result := ChannelMoveResult{Move: move}
	if result.FromEventID, err = insertSyncEvent(ctx, tx, ChannelMovedEventType, nil, move.FromConversationID, payload, now); err != nil {
		return ChannelMoveResult{}, err
	}
	if result.ToEventID, err = insertSyncEvent(ctx, tx, ChannelMovedEventType, nil, move.ToConversationID, payload, now); err != nil {
		return ChannelMoveResult{}, err
	}
	conversation, err := scanConversation(tx.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, move.ToConversationID))
	if err != nil {
		return ChannelMoveResult{}, err
	}
	if access != ChannelAccessPrivate {
		conversation.Kind = CommunityShared
	}
	result.Conversation = conversation
	if err := tx.Commit(); err != nil {
		return ChannelMoveResult{}, err
	}
	return result, nil
}

// replayedMove is the answer to a move request that repeats actorAccountID's
// own latest move of channelID (review L-6): that move put the channel in
// currentConversationID, which it still routes to, in access's class
// ("open" also matches a move that restored "announcement", review L-8).
// Nothing is stored; the answer names no events.
func replayedMove(ctx context.Context, tx *sql.Tx, channelID, currentConversationID, access, actorAccountID string) (ChannelMoveResult, bool, error) {
	var move ChannelMove
	err := tx.QueryRowContext(ctx, `SELECT channel_id, community_id, from_conversation_id, to_conversation_id, from_access, to_access, moved_by
		FROM c3_channel_moves WHERE channel_id = ? ORDER BY id DESC LIMIT 1`, channelID).
		Scan(&move.ChannelID, &move.CommunityID, &move.FromConversationID, &move.ToConversationID, &move.FromAccess, &move.ToAccess, &move.MovedBy)
	if errors.Is(err, sql.ErrNoRows) {
		return ChannelMoveResult{}, false, nil
	}
	if err != nil {
		return ChannelMoveResult{}, false, err
	}
	sameClass := move.ToAccess == access ||
		(access == ChannelAccessOpen && move.ToAccess == ChannelAccessAnnouncement)
	if move.MovedBy != actorAccountID || move.ToConversationID != currentConversationID || !sameClass {
		return ChannelMoveResult{}, false, nil
	}
	if err := tx.QueryRowContext(ctx, `SELECT generation FROM community_channel_routes WHERE channel_id = ?`, channelID).Scan(&move.LayoutGeneration); err != nil {
		return ChannelMoveResult{}, false, err
	}
	conversation, err := scanConversation(tx.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, move.ToConversationID))
	if err != nil {
		return ChannelMoveResult{}, false, err
	}
	if move.ToAccess != ChannelAccessPrivate {
		conversation.Kind = CommunityShared
	}
	return ChannelMoveResult{Move: move, Conversation: conversation, Replayed: true}, true, nil
}

// movedCutoff authorizes a read of fromConversationID's bodies for
// channelID: the caller's device is a current group device of the
// conversation the channel routes to now, its account a member there, and
// a move row took the channel out of fromConversationID. It returns that
// move's cutoff (the latest when the channel left it more than once).
func (s *Store) movedCutoff(ctx context.Context, accountID, deviceID, channelID, fromConversationID string) (int64, error) {
	if !s.c7History {
		return 0, ErrNotFound
	}
	var current string
	err := s.db.QueryRowContext(ctx, `SELECT conversation_id FROM community_channel_routes WHERE channel_id = ?`, channelID).Scan(&current)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	member, err := s.IsConversationMember(ctx, current, accountID)
	if err != nil {
		return 0, err
	}
	if !member {
		return 0, ErrNotMember
	}
	inGroup, err := currentGroupDevice(ctx, s.db, current, deviceID)
	if err != nil {
		return 0, err
	}
	if !inGroup {
		return 0, ErrForbidden
	}
	var cutoff sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT MAX(cutoff_event_id) FROM c3_channel_moves WHERE channel_id = ? AND from_conversation_id = ?`, channelID, fromConversationID).Scan(&cutoff); err != nil {
		return 0, err
	}
	if !cutoff.Valid {
		return 0, ErrNotFound
	}
	return cutoff.Int64, nil
}

// ListMovedHistoryBodies serves, to a member device of the channel's
// current conversation, fromConversationID's stream (stream is channelID,
// or "" for its group-level stream with the history_syncs a walk needs) as
// it stood when the channel left it: bodies up to the move's cutoff, newest
// first, before beforeID when set, with the history fetch's other rules
// (unexpired, undeleted, not hidden, no blocked sender). The join filter
// does not apply: the reader was never in the old group, and the move
// carries what the old group held.
func (s *Store) ListMovedHistoryBodies(ctx context.Context, accountID, deviceID, channelID, fromConversationID, stream, beforeID string, limit int) ([]HistoryBody, error) {
	cutoff, err := s.movedCutoff(ctx, accountID, deviceID, channelID, fromConversationID)
	if err != nil {
		return nil, err
	}
	stream = strings.TrimSpace(stream)
	if stream != "" && stream != channelID {
		return nil, ErrInvalidInput
	}
	if limit <= 0 {
		limit = historyFetchDefaultLimit
	}
	if limit > historyFetchMaxLimit {
		limit = historyFetchMaxLimit
	}
	before := cutoff + 1
	if strings.TrimSpace(beforeID) != "" {
		var cursor sql.NullInt64
		err := s.db.QueryRowContext(ctx, `SELECT sync_event_id FROM envelope_bodies WHERE message_id = ? AND conversation_id = ?`, beforeID, fromConversationID).Scan(&cursor)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && !cursor.Valid) {
			return nil, ErrInvalidInput
		}
		if err != nil {
			return nil, err
		}
		before = min(before, cursor.Int64)
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT me.id, me.sender_device_id, me.idempotency_key, COALESCE(b.channel_id, ''), me.created_at, b.mls_epoch, b.body
		FROM envelope_bodies b
		JOIN message_envelopes me ON me.id = b.message_id
		WHERE b.conversation_id = ?1
		  AND ((?2 = '' AND b.channel_id IS NULL) OR b.channel_id = ?2)
		  AND b.sync_event_id IS NOT NULL
		  AND b.sync_event_id < ?3
		  AND b.history_hidden = 0
		  AND me.deleted_at IS NULL
		  AND (me.expires_at IS NULL OR me.expires_at > ?4)
		  AND NOT EXISTS (SELECT 1 FROM account_blocks bl WHERE bl.blocker_account_id = ?5 AND bl.blocked_account_id = me.sender_account_id)
		ORDER BY b.sync_event_id DESC
		LIMIT ?6`, fromConversationID, stream, before, nowString(), accountID, limit)
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

// ListMovedMemberKeys is ListFormerMemberKeys for a move: the signing key
// of every device with a body in the streams ListMovedHistoryBodies serves
// (fromConversationID's channelID stream and its group-level stream, up to
// the move's cutoff; review L-4), under the same authorization. A device
// that posted only in another channel there, or only after the move, is
// not listed. The app uses a listed key only for a device that is not in
// the destination's tree, with the former-member mark (decision 8).
func (s *Store) ListMovedMemberKeys(ctx context.Context, accountID, deviceID, channelID, fromConversationID string) ([]FormerMemberKey, error) {
	cutoff, err := s.movedCutoff(ctx, accountID, deviceID, channelID, fromConversationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT d.id, d.account_id, d.signing_key, d.revoked_at IS NOT NULL
		FROM devices d
		WHERE d.signing_key IS NOT NULL
		  AND EXISTS (SELECT 1 FROM envelope_bodies b JOIN message_envelopes me ON me.id = b.message_id
		    WHERE b.conversation_id = ?1 AND me.sender_device_id = d.id
		      AND (b.channel_id = ?2 OR b.channel_id IS NULL)
		      AND b.sync_event_id IS NOT NULL AND b.sync_event_id <= ?3)
		ORDER BY d.id
		LIMIT ?4`, fromConversationID, channelID, cutoff, formerMemberKeyLimit)
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
