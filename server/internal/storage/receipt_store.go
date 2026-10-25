package storage

import (
	"context"
	"encoding/json"
	"strconv"
	"time"

	"private-messenger/server/internal/domain"
)

// ReceiptMaxMembers is the largest conversation that keeps delivery cursors,
// lists member receipts and carries typing signals (W5). Past it, or in a
// community channel, ticks and the typing line are not offered: each delivery
// is announced to every member, which grows with the square of the member
// count. The client uses the same number.
const ReceiptMaxMembers = 20

// receiptsApplyTo is a SQL condition on conversation n: a DM or group of at
// most ReceiptMaxMembers members.
func receiptsApplyTo(n string) string {
	return `(EXISTS(SELECT 1 FROM conversations rc WHERE rc.id = ` + n + ` AND rc.kind IN ('dm', 'group'))
	  AND (SELECT COUNT(*) FROM memberships rm WHERE rm.conversation_id = ` + n + `) <= ` + strconv.Itoa(ReceiptMaxMembers) + `)`
}

// ReceiptsApply reports whether ticks and typing are offered in the
// conversation.
func (s *Store) ReceiptsApply(ctx context.Context, conversationID string) (bool, error) {
	var applies bool
	err := s.db.QueryRowContext(ctx, `SELECT `+receiptsApplyTo("?1"), conversationID).Scan(&applies)
	return applies, err
}

// ReadReceiptsEnabled reports whether the account shares read receipts.
func (s *Store) ReadReceiptsEnabled(ctx context.Context, accountID string) (bool, error) {
	var enabled bool
	err := s.db.QueryRowContext(ctx, `SELECT send_read_receipts != 0 FROM accounts WHERE id = ?`, accountID).Scan(&enabled)
	return enabled, err
}

// SetReadReceiptsEnabled switches the account's read receipts on or off for
// all its devices. The cursor already shared stays where it is.
func (s *Store) SetReadReceiptsEnabled(ctx context.Context, accountID string, enabled bool) error {
	_, err := s.db.ExecContext(ctx, `UPDATE accounts SET send_read_receipts = ? WHERE id = ?`, enabled, accountID)
	return err
}

// DeliveryAdvance names a conversation whose delivery cursor for an account
// moves forward to a message.
type DeliveryAdvance struct {
	ConversationID string
	MessageID      string
}

// MemberReceipt is what one other member's cursors say about a conversation.
// Each time is the created_at of the newest message the cursor covers, so a
// reader compares it with the created_at of its own messages. A nil time means
// no such cursor. MemberSince is when the member joined: messages sent before
// it were not theirs to receive, so a reader skips the member for them.
// DeliveredThrough is never earlier than ReadThrough.
type MemberReceipt struct {
	AccountID        string     `json:"account_id"`
	MemberSince      time.Time  `json:"member_since"`
	DeliveredThrough *time.Time `json:"delivered_through"`
	ReadThrough      *time.Time `json:"read_through"`
}

// DeliveryCandidates reads, without writing, the delivery cursors that the
// message creation events of a sync page served to accountID would move.
// Messages the account sent itself, conversations without ticks, and cursors
// that are already at or past the page are left out, so the common repeat
// page costs only reads.
func (s *Store) DeliveryCandidates(ctx context.Context, accountID string, events []domain.SyncEvent) ([]DeliveryAdvance, error) {
	type newest struct {
		id        string
		createdAt time.Time
	}
	latest := map[string]newest{}
	for _, event := range events {
		if event.Type != "message.envelope.created" || event.ConversationID == "" {
			continue
		}
		var payload struct {
			MessageID string `json:"message_id"`
			Envelope  struct {
				SenderAccountID string    `json:"sender_account_id"`
				CreatedAt       time.Time `json:"created_at"`
			} `json:"envelope"`
		}
		if json.Unmarshal(event.Payload, &payload) != nil || payload.MessageID == "" ||
			payload.Envelope.SenderAccountID == accountID {
			continue
		}
		if current, ok := latest[event.ConversationID]; !ok || payload.Envelope.CreatedAt.After(current.createdAt) {
			latest[event.ConversationID] = newest{id: payload.MessageID, createdAt: payload.Envelope.CreatedAt}
		}
	}
	var out []DeliveryAdvance
	for conversationID, message := range latest {
		var moves bool
		err := s.db.QueryRowContext(ctx, `
			SELECT `+receiptsApplyTo("?2")+`
			   AND EXISTS(SELECT 1 FROM message_envelopes WHERE id = ?3 AND conversation_id = ?2)
			   AND NOT EXISTS(
			     SELECT 1 FROM delivery_receipts d
			     JOIN message_envelopes cur ON cur.id = d.message_id
			     WHERE d.account_id = ?1 AND d.conversation_id = ?2
			       AND cur.created_at >= (SELECT created_at FROM message_envelopes WHERE id = ?3))`,
			accountID, conversationID, message.id).Scan(&moves)
		if err != nil {
			return nil, err
		}
		if moves {
			out = append(out, DeliveryAdvance{ConversationID: conversationID, MessageID: message.id})
		}
	}
	return out, nil
}

// ApplyDeliveries writes the delivery cursors of accountID forward and returns
// those that moved, for the caller to announce. Only ids are stored. The write
// re-checks everything, so a stale candidate does no harm.
func (s *Store) ApplyDeliveries(ctx context.Context, accountID string, advances []DeliveryAdvance) ([]DeliveryAdvance, error) {
	if len(advances) == 0 {
		return nil, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var moved []DeliveryAdvance
	for _, advance := range advances {
		result, err := tx.ExecContext(ctx, `
			INSERT INTO delivery_receipts(account_id, conversation_id, message_id)
			SELECT ?1, me.conversation_id, me.id
			FROM message_envelopes me
			WHERE me.id = ?3 AND me.conversation_id = ?2
			  AND EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ?2 AND account_id = ?1)
			  AND `+receiptsApplyTo("?2")+`
			ON CONFLICT(account_id, conversation_id) DO UPDATE SET
				message_id = excluded.message_id
			WHERE (SELECT created_at FROM message_envelopes WHERE id = excluded.message_id) >
			      (SELECT created_at FROM message_envelopes WHERE id = delivery_receipts.message_id)`,
			accountID, advance.ConversationID, advance.MessageID)
		if err != nil {
			return nil, err
		}
		if n, err := result.RowsAffected(); err == nil && n > 0 {
			moved = append(moved, advance)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return moved, nil
}

// ReceiptRecipients lists the members to tell about a receipt of accountID:
// everyone else in the conversation, except accounts in a block with it in
// either direction.
func (s *Store) ReceiptRecipients(ctx context.Context, conversationID, accountID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.account_id FROM memberships m
		WHERE m.conversation_id = ?1 AND m.account_id != ?2
		  AND NOT EXISTS (SELECT 1 FROM account_blocks b
		                  WHERE (b.blocker_account_id = m.account_id AND b.blocked_account_id = ?2)
		                     OR (b.blocker_account_id = ?2 AND b.blocked_account_id = m.account_id))
		ORDER BY m.account_id`, conversationID, accountID)
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

// ConversationReceipts lists the other members' cursors for accountID, a
// member. Accounts in a block with accountID, in either direction, are left
// out. A read cursor implies delivery. Members joined after a message are
// told apart by MemberSince.
func (s *Store) ConversationReceipts(ctx context.Context, conversationID, accountID string) ([]MemberReceipt, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	applies, err := s.ReceiptsApply(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	if !applies {
		return []MemberReceipt{}, nil
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.account_id, m.created_at,
		       (SELECT me.created_at FROM delivery_receipts d
		        JOIN message_envelopes me ON me.id = d.message_id
		        WHERE d.account_id = m.account_id AND d.conversation_id = m.conversation_id),
		       (SELECT me.created_at FROM read_receipts r
		        JOIN message_envelopes me ON me.id = r.shared_message_id
		        WHERE r.account_id = m.account_id AND r.conversation_id = m.conversation_id)
		FROM memberships m
		WHERE m.conversation_id = ?1 AND m.account_id != ?2
		  AND NOT EXISTS (SELECT 1 FROM account_blocks b
		                  WHERE (b.blocker_account_id = ?2 AND b.blocked_account_id = m.account_id)
		                     OR (b.blocker_account_id = m.account_id AND b.blocked_account_id = ?2))
		ORDER BY m.account_id`, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	receipts := []MemberReceipt{}
	for rows.Next() {
		var id, since string
		var delivered, read *string
		if err := rows.Scan(&id, &since, &delivered, &read); err != nil {
			return nil, err
		}
		receipt := MemberReceipt{AccountID: id}
		if t, err := time.Parse(time.RFC3339Nano, since); err == nil {
			receipt.MemberSince = t
		}
		if delivered != nil {
			if t, err := time.Parse(time.RFC3339Nano, *delivered); err == nil {
				receipt.DeliveredThrough = &t
			}
		}
		if read != nil {
			if t, err := time.Parse(time.RFC3339Nano, *read); err == nil {
				receipt.ReadThrough = &t
				if receipt.DeliveredThrough == nil || t.After(*receipt.DeliveredThrough) {
					receipt.DeliveredThrough = &t
				}
			}
		}
		receipts = append(receipts, receipt)
	}
	return receipts, rows.Err()
}
