package storage

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"private-messenger/server/internal/domain"
)

// PostingPolicyEveryone and PostingPolicyAdmins are the stored values of
// conversations.posting_policy (C2).
const (
	PostingPolicyEveryone = "everyone"
	PostingPolicyAdmins   = "admins"
)

// SetConversationPostingPolicy limits posting in a group to its owner and
// admins, or lifts the limit. Only an owner or admin of the group may change
// it, and only groups carry the switch: a DM has two equals, and a community
// channel is limited by its channel kind (announcement).
func (s *Store) SetConversationPostingPolicy(ctx context.Context, conversationID, updatedBy, policy string) (domain.Conversation, int64, error) {
	if policy != PostingPolicyEveryone && policy != PostingPolicyAdmins {
		return domain.Conversation{}, 0, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.Conversation{}, 0, err
	}
	defer tx.Rollback()
	var role string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, updatedBy).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Conversation{}, 0, ErrNotMember
		}
		return domain.Conversation{}, 0, err
	}
	if !domain.CanPostRestricted(role) {
		return domain.Conversation{}, 0, ErrForbidden
	}
	var kind string
	if err := tx.QueryRowContext(ctx, `SELECT kind FROM conversations WHERE id = ?`, conversationID).Scan(&kind); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return domain.Conversation{}, 0, ErrNotFound
		}
		return domain.Conversation{}, 0, err
	}
	if kind != "group" {
		return domain.Conversation{}, 0, ErrInvalidInput
	}
	if _, err := tx.ExecContext(ctx, `UPDATE conversations SET posting_policy = ? WHERE id = ?`, policy, conversationID); err != nil {
		return domain.Conversation{}, 0, err
	}
	conversation, err := scanConversation(tx.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, conversationID))
	if err != nil {
		return domain.Conversation{}, 0, err
	}
	conversation.PostingRestricted = policy == PostingPolicyAdmins
	eventID, err := insertSyncEvent(ctx, tx, "conversation.posting_policy.updated", nil, conversationID, conversation, nowString())
	if err != nil {
		return domain.Conversation{}, 0, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Conversation{}, 0, err
	}
	return conversation, eventID, nil
}

// annotatePostingRestricted sets PostingRestricted on each conversation from
// the stored policy and the channel kind. It is a separate small query so the
// conversation list and read-model queries stay untouched.
func (s *Store) annotatePostingRestricted(ctx context.Context, conversations []domain.Conversation) error {
	if len(conversations) == 0 {
		return nil
	}
	args := make([]interface{}, 0, len(conversations))
	marks := make([]string, 0, len(conversations))
	index := make(map[string][]int, len(conversations))
	for i, c := range conversations {
		args = append(args, c.ID)
		marks = append(marks, "?")
		index[c.ID] = append(index[c.ID], i)
	}
	rows, err := s.db.QueryContext(ctx, `SELECT c.id FROM conversations c LEFT JOIN channels ch ON ch.id = c.channel_id WHERE c.id IN (`+strings.Join(marks, ",")+`) AND (c.posting_policy = 'admins' OR ch.kind = 'announcement')`, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return err
		}
		for _, i := range index[id] {
			conversations[i].PostingRestricted = true
		}
	}
	return rows.Err()
}
