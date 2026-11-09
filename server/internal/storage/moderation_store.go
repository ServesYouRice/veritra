package storage

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
)

var (
	// ErrTimedOut: the sender is in a timeout and may not post.
	ErrTimedOut = errors.New("account is timed out")
	// ErrSlowMode: the sender posted in this channel too recently.
	ErrSlowMode = errors.New("slow mode: wait before posting again")
)

// SlowModeError carries how long the sender still has to wait.
type SlowModeError struct{ Wait time.Duration }

func (e SlowModeError) Error() string { return ErrSlowMode.Error() }

// Is makes errors.Is(err, ErrSlowMode) true.
func (e SlowModeError) Is(target error) bool { return target == ErrSlowMode }

// Moderation action kinds, as stored in moderation_events.
const (
	ModerationKick           = "kick"
	ModerationBan            = "ban"
	ModerationUnban          = "unban"
	ModerationTimeout        = "timeout"
	ModerationTimeoutCleared = "timeout_cleared"
	ModerationSlowMode       = "slow_mode"
	ModerationInvitesPaused  = "invites_paused"
	ModerationInvitesResumed = "invites_resumed"
)

// ModerationEvent is one audit row: ids and an action kind, never a reason.
type ModerationEvent struct {
	ID        string    `json:"id"`
	Actor     string    `json:"actor_account_id"`
	Target    string    `json:"target_account_id,omitempty"`
	ChannelID string    `json:"channel_id,omitempty"`
	Action    string    `json:"action"`
	CreatedAt time.Time `json:"created_at"`
}

// CommunityBan is one ban row.
type CommunityBan struct {
	AccountID string    `json:"account_id"`
	Username  string    `json:"username,omitempty"`
	BannedBy  string    `json:"banned_by"`
	CreatedAt time.Time `json:"created_at"`
}

func appendModerationEventTx(ctx context.Context, tx *sql.Tx, communityID, actor, target, channelID, action string) error {
	id, err := domain.NewID("mod")
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO moderation_events(id, community_id, actor_account_id, target_account_id, channel_id, action, created_at) VALUES(?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?)`, id, communityID, actor, target, channelID, action, nowString())
	return err
}

func communityRoleTx(ctx context.Context, q queryRower, communityID, accountID string) (string, error) {
	var role string
	err := q.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, accountID).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotMember
	}
	return role, err
}

// communityBannedTx says whether the account is banned from the community.
func communityBannedTx(ctx context.Context, q queryRower, communityID, accountID string) (bool, error) {
	n, err := countRows(ctx, q, `SELECT COUNT(*) FROM member_bans WHERE community_id = ? AND account_id = ?`, communityID, accountID)
	return n > 0, err
}

// conversationCommunityBannedTx applies communityBannedTx to the community a
// conversation belongs to; a conversation outside any community is never banned.
func conversationCommunityBannedTx(ctx context.Context, q queryRower, conversationID, accountID string) (bool, error) {
	n, err := countRows(ctx, q, `SELECT COUNT(*) FROM conversations c JOIN member_bans b ON b.community_id = c.community_id WHERE c.id = ? AND b.account_id = ?`, conversationID, accountID)
	return n > 0, err
}

// KickCommunityMember removes a member, rank-checked, and records it in the
// audit log. The account may be added again (a ban is the lasting form).
func (s *Store) KickCommunityMember(ctx context.Context, communityID, actorAccountID, targetAccountID string) (CommunityRemoval, error) {
	if actorAccountID == targetAccountID {
		return CommunityRemoval{}, ErrForbidden
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CommunityRemoval{}, err
	}
	defer tx.Rollback()
	removal, err := s.removeCommunityMemberTx(ctx, tx, communityID, actorAccountID, targetAccountID)
	if err != nil {
		return CommunityRemoval{}, err
	}
	if err := appendModerationEventTx(ctx, tx, communityID, actorAccountID, targetAccountID, "", ModerationKick); err != nil {
		return CommunityRemoval{}, err
	}
	return removal, tx.Commit()
}

// BanCommunityMember removes the member (when it is one) and then records the
// ban in the same transaction, so a ban never leaves the account in. A moderator
// bans only a member it outranks; banning someone who already left needs an
// admin. The banned account cannot be added, join or redeem an invitation.
func (s *Store) BanCommunityMember(ctx context.Context, communityID, actorAccountID, targetAccountID string) (CommunityRemoval, error) {
	if actorAccountID == targetAccountID {
		return CommunityRemoval{}, ErrForbidden
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CommunityRemoval{}, err
	}
	defer tx.Rollback()
	actorRole, err := communityRoleTx(ctx, tx, communityID, actorAccountID)
	if err != nil {
		return CommunityRemoval{}, err
	}
	var removal CommunityRemoval
	targetRole, err := communityRoleTx(ctx, tx, communityID, targetAccountID)
	switch {
	case err == nil:
		if !domain.CanModerate(actorRole, targetRole, false) {
			return CommunityRemoval{}, ErrForbidden
		}
		removal, err = s.removeCommunityMemberTx(ctx, tx, communityID, actorAccountID, targetAccountID)
		if err != nil {
			return CommunityRemoval{}, err
		}
	case errors.Is(err, ErrNotMember):
		if !domain.CanManageInvites(actorRole) {
			return CommunityRemoval{}, ErrForbidden
		}
		active, err := countRows(ctx, tx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, targetAccountID)
		if err != nil {
			return CommunityRemoval{}, err
		}
		if active == 0 {
			return CommunityRemoval{}, ErrNotFound
		}
	default:
		return CommunityRemoval{}, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO member_bans(community_id, account_id, banned_by, created_at) VALUES(?, ?, ?, ?) ON CONFLICT(community_id, account_id) DO NOTHING`, communityID, targetAccountID, actorAccountID, nowString()); err != nil {
		return CommunityRemoval{}, err
	}
	if err := cancelPendingJoinRequestsTx(ctx, tx, MembershipTarget{Kind: domain.InviteTargetCommunity, ID: communityID}, targetAccountID); err != nil {
		return CommunityRemoval{}, err
	}
	if err := appendModerationEventTx(ctx, tx, communityID, actorAccountID, targetAccountID, "", ModerationBan); err != nil {
		return CommunityRemoval{}, err
	}
	return removal, tx.Commit()
}

// UnbanCommunityMember deletes a ban. It does not add the account back.
func (s *Store) UnbanCommunityMember(ctx context.Context, communityID, actorAccountID, targetAccountID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	role, err := communityRoleTx(ctx, tx, communityID, actorAccountID)
	if err != nil {
		return err
	}
	// Admins and above lift bans: a moderator must not undo an admin's ban or
	// a pre-ban only an admin can place (rank rule on every action).
	if !domain.CanManageInvites(role) {
		return ErrForbidden
	}
	result, err := tx.ExecContext(ctx, `DELETE FROM member_bans WHERE community_id = ? AND account_id = ?`, communityID, targetAccountID)
	if err != nil {
		return err
	}
	if n, err := result.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrNotFound
	}
	if err := appendModerationEventTx(ctx, tx, communityID, actorAccountID, targetAccountID, "", ModerationUnban); err != nil {
		return err
	}
	return tx.Commit()
}

// ListCommunityBans lists a community's bans for its moderators and above.
func (s *Store) ListCommunityBans(ctx context.Context, communityID, actorAccountID string) ([]CommunityBan, error) {
	role, err := communityRoleTx(ctx, s.db, communityID, actorAccountID)
	if err != nil {
		return nil, err
	}
	if !domain.CanManageMembers(role) {
		return nil, ErrForbidden
	}
	rows, err := s.db.QueryContext(ctx, `SELECT b.account_id, COALESCE(a.username, ''), b.banned_by, b.created_at FROM member_bans b LEFT JOIN accounts a ON a.id = b.account_id WHERE b.community_id = ? ORDER BY b.created_at, b.account_id`, communityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	bans := make([]CommunityBan, 0)
	for rows.Next() {
		var ban CommunityBan
		var created string
		if err := rows.Scan(&ban.AccountID, &ban.Username, &ban.BannedBy, &created); err != nil {
			return nil, err
		}
		ban.CreatedAt = parseTime(created)
		bans = append(bans, ban)
	}
	return bans, rows.Err()
}

// SetMemberTimeout mutes a member for d (0 clears it). The actor must outrank
// the target (CanModerate); d is bounded by domain.MaxTimeout.
func (s *Store) SetMemberTimeout(ctx context.Context, communityID, actorAccountID, targetAccountID string, d time.Duration) (*time.Time, error) {
	if d != 0 && !domain.ValidTimeout(d) {
		return nil, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	actorRole, err := communityRoleTx(ctx, tx, communityID, actorAccountID)
	if err != nil {
		return nil, err
	}
	targetRole, err := communityRoleTx(ctx, tx, communityID, targetAccountID)
	if errors.Is(err, ErrNotMember) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if !domain.CanModerate(actorRole, targetRole, actorAccountID == targetAccountID) {
		return nil, ErrForbidden
	}
	var until *time.Time
	action := ModerationTimeoutCleared
	var arg interface{}
	if d > 0 {
		end := time.Now().UTC().Add(d)
		until = &end
		arg = formatTime(end)
		action = ModerationTimeout
	}
	if _, err := tx.ExecContext(ctx, `UPDATE memberships SET timeout_until = ? WHERE community_id = ? AND account_id = ?`, arg, communityID, targetAccountID); err != nil {
		return nil, err
	}
	if err := appendModerationEventTx(ctx, tx, communityID, actorAccountID, targetAccountID, "", action); err != nil {
		return nil, err
	}
	return until, tx.Commit()
}

// SetChannelSlowMode sets the gap between a non-moderator's posts in a channel
// (0 turns it off). Moderators and above set it.
func (s *Store) SetChannelSlowMode(ctx context.Context, communityID, channelID, actorAccountID string, d time.Duration) error {
	if !domain.ValidSlowMode(d) || d%time.Second != 0 {
		return ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	role, err := communityRoleTx(ctx, tx, communityID, actorAccountID)
	if err != nil {
		return err
	}
	if !domain.CanManageMembers(role) {
		return ErrForbidden
	}
	result, err := tx.ExecContext(ctx, `UPDATE channels SET slow_mode_seconds = ? WHERE id = ? AND community_id = ?`, int64(d/time.Second), channelID, communityID)
	if err != nil {
		return err
	}
	if n, err := result.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrNotFound
	}
	if err := appendModerationEventTx(ctx, tx, communityID, actorAccountID, "", channelID, ModerationSlowMode); err != nil {
		return err
	}
	return tx.Commit()
}

// SetInvitesPaused refuses invitation use for d (0 resumes). Admins and above.
func (s *Store) SetInvitesPaused(ctx context.Context, communityID, actorAccountID string, d time.Duration) (*time.Time, error) {
	if d != 0 && !domain.ValidTimeout(d) {
		return nil, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	role, err := communityRoleTx(ctx, tx, communityID, actorAccountID)
	if err != nil {
		return nil, err
	}
	if !domain.CanManageInvites(role) {
		return nil, ErrForbidden
	}
	var until *time.Time
	var arg interface{}
	action := ModerationInvitesResumed
	if d > 0 {
		end := time.Now().UTC().Add(d)
		until, arg, action = &end, formatTime(end), ModerationInvitesPaused
	}
	if _, err := tx.ExecContext(ctx, `UPDATE communities SET invites_paused_until = ? WHERE id = ?`, arg, communityID); err != nil {
		return nil, err
	}
	if err := appendModerationEventTx(ctx, tx, communityID, actorAccountID, "", "", action); err != nil {
		return nil, err
	}
	return until, tx.Commit()
}

// ListModerationEvents returns the audit log, newest first, to admins and
// above. It holds ids and action kinds only.
func (s *Store) ListModerationEvents(ctx context.Context, communityID, actorAccountID string, limit int) ([]ModerationEvent, error) {
	role, err := communityRoleTx(ctx, s.db, communityID, actorAccountID)
	if err != nil {
		return nil, err
	}
	if !domain.CanManageInvites(role) {
		return nil, ErrForbidden
	}
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, actor_account_id, COALESCE(target_account_id, ''), COALESCE(channel_id, ''), action, created_at FROM moderation_events WHERE community_id = ? ORDER BY created_at DESC, id DESC LIMIT ?`, communityID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := make([]ModerationEvent, 0)
	for rows.Next() {
		var e ModerationEvent
		var created string
		if err := rows.Scan(&e.ID, &e.Actor, &e.Target, &e.ChannelID, &e.Action, &created); err != nil {
			return nil, err
		}
		e.CreatedAt = parseTime(created)
		events = append(events, e)
	}
	return events, rows.Err()
}

// checkPostingAllowedTx enforces timeout and slow mode for a post (C5). The
// server's clock is authoritative. A timeout binds whoever carries it; slow
// mode exempts moderators and above (domain.SlowModeWait). routeChannelID is
// the channel the post names in a shared group, or "" for a legacy channel
// conversation (then the conversation's own channel applies).
func checkPostingAllowedTx(ctx context.Context, tx *sql.Tx, conversationID, accountID, senderRole, routeChannelID string, now time.Time) error {
	if err := checkNotTimedOutTx(ctx, tx, conversationID, accountID, now); err != nil {
		return err
	}
	var communityID, convChannel sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT community_id, channel_id FROM conversations WHERE id = ?`, conversationID).Scan(&communityID, &convChannel); err != nil {
		return err
	}
	if !communityID.Valid {
		return nil
	}
	channelID := routeChannelID
	if channelID == "" && convChannel.Valid {
		channelID = convChannel.String
	}
	if channelID == "" {
		return nil
	}
	var seconds int64
	err := tx.QueryRowContext(ctx, `SELECT slow_mode_seconds FROM channels WHERE id = ?`, channelID).Scan(&seconds)
	if errors.Is(err, sql.ErrNoRows) || seconds == 0 {
		return nil
	}
	if err != nil {
		return err
	}
	var last sql.NullString
	if routeChannelID != "" {
		err = tx.QueryRowContext(ctx, `SELECT created_at FROM message_envelopes WHERE conversation_id = ? AND sender_account_id = ? AND json_extract(crypto_metadata_json, '$.channel_id') = ? ORDER BY created_at DESC LIMIT 1`, conversationID, accountID, routeChannelID).Scan(&last)
	} else {
		err = tx.QueryRowContext(ctx, `SELECT created_at FROM message_envelopes WHERE conversation_id = ? AND sender_account_id = ? ORDER BY created_at DESC LIMIT 1`, conversationID, accountID).Scan(&last)
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	var lastPost *time.Time
	if last.Valid {
		t := parseTime(last.String)
		lastPost = &t
	}
	if wait := domain.SlowModeWait(senderRole, time.Duration(seconds)*time.Second, lastPost, now); wait > 0 {
		return SlowModeError{Wait: wait}
	}
	return nil
}

// checkNotTimedOutTx refuses an account in a timeout in the community the
// conversation belongs to. It guards every way of adding content: new posts,
// edits and reactions (a timeout must not be sidestepped by rewriting or
// reacting to an older message).
func checkNotTimedOutTx(ctx context.Context, tx *sql.Tx, conversationID, accountID string, now time.Time) error {
	var timeout sql.NullString
	err := tx.QueryRowContext(ctx, `SELECT m.timeout_until FROM conversations c JOIN memberships m ON m.community_id = c.community_id AND m.account_id = ? WHERE c.id = ?`, accountID, conversationID).Scan(&timeout)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if timeout.Valid {
		end := parseTime(timeout.String)
		if domain.TimedOut(&end, now) {
			return ErrTimedOut
		}
	}
	return nil
}

// ChannelSlowMode is one channel's slow-mode setting.
type ChannelSlowMode struct {
	ChannelID       string `json:"channel_id"`
	SlowModeSeconds int64  `json:"slow_mode_seconds"`
}

// ModerationState is what a moderation screen shows besides the lists.
type ModerationState struct {
	InvitesPausedUntil *time.Time        `json:"invites_paused_until"`
	Channels           []ChannelSlowMode `json:"channels"`
}

// GetModerationState returns the pause and the channels' slow modes to the
// community's moderators and above.
func (s *Store) GetModerationState(ctx context.Context, communityID, actorAccountID string) (ModerationState, error) {
	role, err := communityRoleTx(ctx, s.db, communityID, actorAccountID)
	if err != nil {
		return ModerationState{}, err
	}
	if !domain.CanManageMembers(role) {
		return ModerationState{}, ErrForbidden
	}
	state := ModerationState{Channels: make([]ChannelSlowMode, 0)}
	var paused sql.NullString
	if err := s.db.QueryRowContext(ctx, `SELECT invites_paused_until FROM communities WHERE id = ?`, communityID).Scan(&paused); err != nil {
		return ModerationState{}, err
	}
	if paused.Valid {
		if end := parseTime(paused.String); end.After(time.Now().UTC()) {
			state.InvitesPausedUntil = &end
		}
	}
	// Same visibility as the channel list: a private channel is shown only to
	// members of its conversation, so its id and setting do not leak.
	rows, err := s.db.QueryContext(ctx, `
		SELECT ch.id, ch.slow_mode_seconds
		FROM channels ch
		LEFT JOIN community_channel_routes r ON r.channel_id = ch.id
		WHERE ch.community_id = ?1
		  AND (r.channel_id IS NULL OR r.access_mode <> 'private'
		       OR EXISTS (SELECT 1 FROM memberships m WHERE m.conversation_id = r.conversation_id AND m.account_id = ?2))
		ORDER BY ch.created_at, ch.id`, communityID, actorAccountID)
	if err != nil {
		return ModerationState{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var c ChannelSlowMode
		if err := rows.Scan(&c.ChannelID, &c.SlowModeSeconds); err != nil {
			return ModerationState{}, err
		}
		state.Channels = append(state.Channels, c)
	}
	return state, rows.Err()
}
