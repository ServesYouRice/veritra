package storage

import (
	"context"
	"database/sql"
	"errors"

	"private-messenger/server/internal/domain"
)

// ChannelRemoval names the events one channel conversation got when a member
// left or was removed from its community.
type ChannelRemoval struct {
	ConversationID          string
	RemainingMembersEventID int64
	RemovedMemberEventID    int64
}

// CommunityRemoval is the result of RemoveCommunityMember: one entry per
// channel conversation the account was taken out of.
type CommunityRemoval struct {
	Channels []ChannelRemoval
}

// RemoveCommunityMember takes an account out of a community and out of every
// channel conversation it was in, in one transaction (C1). Leaving (actor is
// target) is allowed to everyone but the last owner; removing someone needs a
// member manager of strictly higher rank. Per channel it writes the same
// events as RemoveConversationMember, so remaining members' apps reconcile
// each channel's MLS group through the existing path.
//
// The server drops access at once. The removed account's devices leave each
// MLS group only when a remaining member's removal commit lands.
func (s *Store) RemoveCommunityMember(ctx context.Context, communityID, actorAccountID, targetAccountID string) (CommunityRemoval, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CommunityRemoval{}, err
	}
	defer tx.Rollback()
	var actorRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, actorAccountID).Scan(&actorRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return CommunityRemoval{}, ErrNotMember
		}
		return CommunityRemoval{}, err
	}
	var targetRole string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, targetAccountID).Scan(&targetRole); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return CommunityRemoval{}, ErrNotFound
		}
		return CommunityRemoval{}, err
	}
	if actorAccountID == targetAccountID {
		if targetRole == domain.RoleOwner {
			owners, err := countRows(ctx, tx, `SELECT COUNT(*) FROM memberships WHERE community_id = ? AND role = ?`, communityID, domain.RoleOwner)
			if err != nil {
				return CommunityRemoval{}, err
			}
			if owners <= 1 {
				return CommunityRemoval{}, ErrLastOwner
			}
		}
	} else if !domain.CanManageMembers(actorRole) || domain.RoleRank(targetRole) >= domain.RoleRank(actorRole) {
		return CommunityRemoval{}, ErrForbidden
	}
	rows, err := tx.QueryContext(ctx, `
		SELECT c.id FROM conversations c
		JOIN memberships m ON m.conversation_id = c.id AND m.account_id = ?
		WHERE c.community_id = ? AND c.kind = 'community_channel'
		ORDER BY c.id`, targetAccountID, communityID)
	if err != nil {
		return CommunityRemoval{}, err
	}
	conversationIDs := make([]string, 0)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return CommunityRemoval{}, err
		}
		conversationIDs = append(conversationIDs, id)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return CommunityRemoval{}, err
	}
	if err := rows.Close(); err != nil {
		return CommunityRemoval{}, err
	}
	eventType := "membership.removed"
	if actorAccountID == targetAccountID {
		eventType = "membership.left"
	}
	now := nowString()
	removal := CommunityRemoval{Channels: make([]ChannelRemoval, 0, len(conversationIDs))}
	for _, conversationID := range conversationIDs {
		if _, err := tx.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, targetAccountID); err != nil {
			return CommunityRemoval{}, err
		}
		// Cursors of a member who is gone must not come back if they join again.
		for _, query := range []string{
			`DELETE FROM delivery_receipts WHERE conversation_id = ? AND account_id = ?`,
			`DELETE FROM read_receipts WHERE conversation_id = ? AND account_id = ?`,
		} {
			if _, err := tx.ExecContext(ctx, query, conversationID, targetAccountID); err != nil {
				return CommunityRemoval{}, err
			}
		}
		payload := map[string]string{"conversation_id": conversationID, "community_id": communityID, "account_id": targetAccountID, "mls_coordination": "pending"}
		remainingID, err := insertSyncEvent(ctx, tx, eventType, nil, conversationID, payload, now)
		if err != nil {
			return CommunityRemoval{}, err
		}
		removedID, err := insertSyncEvent(ctx, tx, eventType, &targetAccountID, "", payload, now)
		if err != nil {
			return CommunityRemoval{}, err
		}
		removal.Channels = append(removal.Channels, ChannelRemoval{ConversationID: conversationID, RemainingMembersEventID: remainingID, RemovedMemberEventID: removedID})
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, targetAccountID); err != nil {
		return CommunityRemoval{}, err
	}
	// A community without channels still tells the removed account.
	if len(conversationIDs) == 0 {
		payload := map[string]string{"community_id": communityID, "account_id": targetAccountID}
		if _, err := insertSyncEvent(ctx, tx, eventType, &targetAccountID, "", payload, now); err != nil {
			return CommunityRemoval{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return CommunityRemoval{}, err
	}
	return removal, nil
}
