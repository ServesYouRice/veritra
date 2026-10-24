package storage

import (
	"context"
	"encoding/json"
	"strconv"
	"time"

	"private-messenger/server/internal/domain"
)

// ReceiptMaxMembers is the largest conversation that keeps delivery cursors
// and lists member receipts (W5). Past it, or in a community channel, ticks
// are not offered: each delivery would be announced to every member, which
// grows with the square of the member count. The client's typing line uses
// the same number.
const ReceiptMaxMembers = 20

// receiptsApplyTo is a SQL condition on conversation ?N: a DM or group of at
// most ReceiptMaxMembers members.
func receiptsApplyTo(n string) string {
	return `EXISTS(SELECT 1 FROM conversations rc WHERE rc.id = ` + n + ` AND rc.kind IN ('dm', 'group'))
	  AND (SELECT COUNT(*) FROM memberships rm WHERE rm.conversation_id = ` + n + `) <= ` + strconv.Itoa(ReceiptMaxMembers)
}

// ReadReceiptsEnabled reports whether the account shares read receipts.
func (s *Store) ReadReceiptsEnabled(ctx context.Context, accountID string) (bool, error) {
	var enabled bool
	err := s.db.QueryRowContext(ctx, `SELECT send_read_receipts != 0 FROM accounts WHERE id = ?`, accountID).Scan(&enabled)
	return enabled, err
}

// SetReadReceiptsEnabled switches the account's read receipts on or off for
// all its devices. Cursors already shared stay as they are.
func (s *Store) SetReadReceiptsEnabled(ctx context.Context, accountID string, enabled bool) error {
	_, err := s.db.ExecContext(ctx, `UPDATE accounts SET send_read_receipts = ? WHERE id = ?`, enabled, accountID)
	return err
}

// DeliveryAdvance names a conversation whose delivery cursor for an account
// moved forward.
type DeliveryAdvance struct {
	ConversationID string
	MessageID      string
}

// MemberReceipt is what one other member's cursors say about a conversation.
// Each time is the created_at of the newest message the cursor covers, so a
// reader compares it with the created_at of its own messages. A nil time
// means no such cursor. ReadThrough is nil while the member keeps read
// receipts off (their cursor is private), and DeliveredThrough is never
// earlier than a visible ReadThrough.
type MemberReceipt struct {
	AccountID        string     `json:"account_id"`
	DeliveredThrough *time.Time `json:"delivered_through"`
	ReadThrough      *time.Time `json:"read_through"`
}

// RecordDelivered advances accountID's delivery cursors for the message
// creation events of a sync page its device was just served. Messages the
// account sent itself are skipped. It returns the cursors that moved so the
// caller can announce them. Only ids and times are stored.
func (s *Store) RecordDelivered(ctx context.Context, accountID string, events []domain.SyncEvent) ([]DeliveryAdvance, error) {
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
	if len(latest) == 0 {
		return nil, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	now := nowString()
	var advanced []DeliveryAdvance
	for conversationID, message := range latest {
		// Moves forward only, by the message's created_at, and only for a
		// message that still exists and belongs to a conversation the
		// account is in.
		result, err := tx.ExecContext(ctx, `
			INSERT INTO delivery_receipts(account_id, conversation_id, message_id, delivered_at)
			SELECT ?1, me.conversation_id, me.id, ?2
			FROM message_envelopes me
			WHERE me.id = ?3 AND me.conversation_id = ?4
			  AND EXISTS(SELECT 1 FROM memberships WHERE conversation_id = ?4 AND account_id = ?1)
			  AND `+receiptsApplyTo("?4")+`
			ON CONFLICT(account_id, conversation_id) DO UPDATE SET
				message_id = excluded.message_id,
				delivered_at = excluded.delivered_at
			WHERE (SELECT created_at FROM message_envelopes WHERE id = excluded.message_id) >
			      (SELECT created_at FROM message_envelopes WHERE id = delivery_receipts.message_id)`,
			accountID, now, message.id, conversationID)
		if err != nil {
			return nil, err
		}
		if n, err := result.RowsAffected(); err == nil && n > 0 {
			advanced = append(advanced, DeliveryAdvance{ConversationID: conversationID, MessageID: message.id})
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return advanced, nil
}

// ConversationReceipts lists the other members' cursors for accountID, a
// member. Accounts accountID blocked are left out, as their read receipts are
// left out of its sync events. A read cursor implies delivery.
func (s *Store) ConversationReceipts(ctx context.Context, conversationID, accountID string) ([]MemberReceipt, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	if !member {
		return nil, ErrNotMember
	}
	var applies bool
	if err := s.db.QueryRowContext(ctx, `SELECT `+receiptsApplyTo("?1"), conversationID).Scan(&applies); err != nil {
		return nil, err
	}
	if !applies {
		return []MemberReceipt{}, nil
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.account_id,
		       (SELECT me.created_at FROM delivery_receipts d
		        JOIN message_envelopes me ON me.id = d.message_id
		        WHERE d.account_id = m.account_id AND d.conversation_id = m.conversation_id),
		       (SELECT me.created_at FROM read_receipts r
		        JOIN message_envelopes me ON me.id = r.message_id
		        WHERE r.account_id = m.account_id AND r.conversation_id = m.conversation_id AND r.private = 0)
		FROM memberships m
		WHERE m.conversation_id = ?1 AND m.account_id != ?2
		  AND NOT EXISTS (SELECT 1 FROM account_blocks b
		                  WHERE b.blocker_account_id = ?2 AND b.blocked_account_id = m.account_id)
		ORDER BY m.account_id`, conversationID, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	receipts := []MemberReceipt{}
	for rows.Next() {
		var id string
		var delivered, read *string
		if err := rows.Scan(&id, &delivered, &read); err != nil {
			return nil, err
		}
		receipt := MemberReceipt{AccountID: id}
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
