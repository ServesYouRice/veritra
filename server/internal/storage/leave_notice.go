package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

// C4 leave notice (docs/crypto.md, "C4 app wiring", member_leave). A
// governing member's app sends its own member_leave before it asks to leave.
// Posting rules must not stop it: a moderator in an admins-only group, a
// voter in an announcement channel or a timed-out member must still be able
// to leave with its proof. The server cannot read the payload type, so the
// app marks the envelope in the clear metadata and the server exempts a
// marked envelope from C2, the C5 timeout and slow mode, within limits that
// keep the mark from being a way around them:
//
//   - only in a record group (kind "group" outside a community, or a
//     community's shared conversation);
//   - no attachments, replies, threads or franking commitment: a leave proof
//     carries none, so nothing a reader would see rides along;
//   - at most LeaveNoticesPerInterval marked envelopes per sender account
//     and membership per LeaveNoticeInterval: the member_leave and, from
//     crypto ABI 24, the member_leave_signed that carries the leave
//     statement a committer puts in the commit ("C4 leave proof in the
//     commit").
//
// Receiving apps drop a marked envelope whose payload is not a member_leave
// or member_leave_signed (or a hidden type they do not know), so a marked
// post shows nothing to anyone.

// EnvelopeLeaveNoticeKey marks an envelope as a C4 leave notice. Its value is
// the JSON literal true; any other value is refused.
const EnvelopeLeaveNoticeKey = "c4_leave"

// LeaveNoticeInterval bounds marked envelopes per sender and membership.
const LeaveNoticeInterval = time.Hour

// LeaveNoticesPerInterval is how many marked envelopes one interval admits.
const LeaveNoticesPerInterval = 2

// ErrLeaveNoticeLimited answers a leave notice over the limit.
var ErrLeaveNoticeLimited = errors.New("leave notice limited")

// LeaveNoticeLimitedError carries the wait until the next notice is allowed.
type LeaveNoticeLimitedError struct{ Wait time.Duration }

func (e LeaveNoticeLimitedError) Error() string { return ErrLeaveNoticeLimited.Error() }

func (e LeaveNoticeLimitedError) Unwrap() error { return ErrLeaveNoticeLimited }

// metadataLeaveNotice reports whether metadata carries the leave mark. A mark
// with another value than true, or metadata naming a key twice, is refused
// (ErrInvalidChannelRoute): the stored row must say what admission checked.
func metadataLeaveNotice(metadata json.RawMessage) (bool, error) {
	fields, ok := metadataFields(metadata)
	if !ok {
		return false, nil
	}
	raw, marked := fields[EnvelopeLeaveNoticeKey]
	if !marked {
		return false, nil
	}
	if strings.TrimSpace(string(raw)) != "true" || metadataRepeatsKey(metadata) {
		return false, ErrInvalidChannelRoute
	}
	return true, nil
}

// checkLeaveNoticeTx admits a marked envelope, or refuses it.
func checkLeaveNoticeTx(ctx context.Context, tx *sql.Tx, envelope domain.MessageEnvelope, attachments int, now time.Time) error {
	// An expiry is allowed: a disappearing group's own timer may set one, and
	// retention bounds it after this check as for any envelope.
	if attachments > 0 || len(envelope.FrankCommit) > 0 ||
		(envelope.ReplyToID != nil && strings.TrimSpace(*envelope.ReplyToID) != "") ||
		(envelope.ThreadRootID != nil && strings.TrimSpace(*envelope.ThreadRootID) != "") {
		return ErrInvalidInput
	}
	var kind string
	var community sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT kind, community_id FROM conversations WHERE id = ?`, envelope.ConversationID).Scan(&kind, &community); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	shared, err := isSharedConversation(ctx, tx, envelope.ConversationID)
	if err != nil {
		return err
	}
	if !shared && (kind != "group" || community.Valid) {
		return ErrInvalidInput
	}
	var joined string
	if err := tx.QueryRowContext(ctx, `SELECT created_at FROM memberships WHERE conversation_id = ? AND account_id = ?`, envelope.ConversationID, envelope.SenderAccountID).Scan(&joined); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotMember
		}
		return err
	}
	since := now.Add(-LeaveNoticeInterval)
	if start := parseTime(joined); start.After(since) {
		since = start
	}
	var count int
	var oldest sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), MIN(created_at) FROM message_envelopes WHERE conversation_id = ? AND sender_account_id = ? AND json_extract(crypto_metadata_json, '$.c4_leave') = 1 AND created_at >= ?`, envelope.ConversationID, envelope.SenderAccountID, formatTime(since)).Scan(&count, &oldest); err != nil {
		return err
	}
	if count >= LeaveNoticesPerInterval && oldest.Valid {
		// Room opens when the oldest notice in the window leaves it.
		wait := parseTime(oldest.String).Add(LeaveNoticeInterval).Sub(now)
		if wait < time.Second {
			wait = time.Second
		}
		return LeaveNoticeLimitedError{Wait: wait}
	}
	return nil
}
