package storage

import (
	"context"
	"database/sql"
	"errors"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/config"
)

// Admission limits (card I49, T49D). Every check runs inside the write
// transaction that adds the row, on the single writer connection, so two
// concurrent requests cannot both pass a limit with one free slot.
//
// A refusal names only the caller's own state, or that of a conversation or
// community the caller already belongs to. When a limit of another account
// stops a write (an account added to more conversations than its limit), the
// error is ErrForbidden, the same one a block between the two gives, so it
// reveals nothing new about that account.
var (
	ErrDeviceLimit             = errors.New("account has the maximum number of devices")
	ErrDeviceLinkLimit         = errors.New("account has the maximum number of pending device links")
	ErrConversationLimit       = errors.New("account belongs to the maximum number of conversations")
	ErrConversationMemberLimit = errors.New("conversation has the maximum number of members")
)

func resolveLimits(limits config.Limits) config.Limits {
	limits = limits.WithDefaults()
	if limits.InstanceStorageBytes == 0 {
		limits.InstanceStorageBytes = config.LegacyInstanceStorageMiB << 20
	}
	limits.AccountStorageBytes = min(limits.AccountStorageBytes, limits.InstanceStorageBytes)
	return limits
}

// Limits returns the limits this store enforces, defaults applied.
func (s *Store) Limits() config.Limits { return s.limits }

// AdmissionCounters counts refusals by limit, for metrics.
func (s *Store) AdmissionCounters() *admission.Counters { return s.admission }

func (s *Store) refuse(limit string, err error) error {
	s.admission.Reject(limit)
	return err
}

type queryRower interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}

func countRows(ctx context.Context, q queryRower, query string, args ...interface{}) (int, error) {
	var n int
	err := q.QueryRowContext(ctx, query, args...).Scan(&n)
	return n, err
}

// checkOwnConversations refuses a write that would put accountID, the
// acting account, in more than the conversation limit.
func (s *Store) checkOwnConversations(ctx context.Context, tx *sql.Tx, accountID string, adding int) error {
	n, err := countRows(ctx, tx, `SELECT COUNT(conversation_id) FROM memberships WHERE account_id = ?`, accountID)
	if err != nil {
		return err
	}
	if n+adding > s.limits.ConversationsPerAccount {
		return s.refuse(admission.Conversations, ErrConversationLimit)
	}
	return nil
}

// checkOtherConversations is the same limit for an account someone else is
// adding; its refusal is indistinguishable from a block.
func (s *Store) checkOtherConversations(ctx context.Context, tx *sql.Tx, accountID string, adding int) error {
	n, err := countRows(ctx, tx, `SELECT COUNT(conversation_id) FROM memberships WHERE account_id = ?`, accountID)
	if err != nil {
		return err
	}
	if n+adding > s.limits.ConversationsPerAccount {
		return s.refuse(admission.Conversations, ErrForbidden)
	}
	return nil
}

// checkMembers refuses a conversation or community that would exceed the
// member limit once adding more members join.
func (s *Store) checkMembers(current, adding int) error {
	if current+adding > s.limits.ConversationMembers {
		return s.refuse(admission.Members, ErrConversationMemberLimit)
	}
	return nil
}

func conversationMemberCount(ctx context.Context, tx *sql.Tx, conversationID string) (int, error) {
	return countRows(ctx, tx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ?`, conversationID)
}

func communityMemberCount(ctx context.Context, tx *sql.Tx, communityID string) (int, error) {
	return countRows(ctx, tx, `SELECT COUNT(*) FROM memberships WHERE community_id = ?`, communityID)
}

// largestChannel is the member count of the community's largest channel.
func largestChannel(ctx context.Context, tx *sql.Tx, communityID string) (int, error) {
	return countRows(ctx, tx, `
		SELECT COALESCE(MAX(members), 0) FROM (
			SELECT COUNT(*) AS members FROM memberships m
			JOIN conversations c ON c.id = m.conversation_id
			WHERE c.community_id = ? AND c.kind = 'community_channel'
			GROUP BY m.conversation_id
		)`, communityID)
}

// checkNewConversationMember applies the member limit to the conversation
// and the conversation limit to the account joining it.
func (s *Store) checkNewConversationMember(ctx context.Context, tx *sql.Tx, conversationID, accountID string) error {
	members, err := conversationMemberCount(ctx, tx, conversationID)
	if err != nil {
		return err
	}
	if err := s.checkMembers(members, 1); err != nil {
		return err
	}
	return s.checkOtherConversations(ctx, tx, accountID, 1)
}

// checkNewCommunityMember: a new community member also joins every channel,
// so both the community and its largest channel must have room, and the
// account must have room for every channel.
func (s *Store) checkNewCommunityMember(ctx context.Context, tx *sql.Tx, communityID, accountID string) error {
	members, err := communityMemberCount(ctx, tx, communityID)
	if err != nil {
		return err
	}
	if err := s.checkMembers(members, 1); err != nil {
		return err
	}
	largest, err := largestChannel(ctx, tx, communityID)
	if err != nil {
		return err
	}
	if err := s.checkMembers(largest, 1); err != nil {
		return err
	}
	channels, err := countRows(ctx, tx, `SELECT COUNT(*) FROM conversations WHERE community_id = ? AND kind = 'community_channel'`, communityID)
	if err != nil {
		return err
	}
	return s.checkOtherConversations(ctx, tx, accountID, channels)
}

func (s *Store) checkDevices(ctx context.Context, q queryRower, accountID string) error {
	n, err := countRows(ctx, q, `SELECT COUNT(*) FROM devices WHERE account_id = ? AND revoked_at IS NULL`, accountID)
	if err != nil {
		return err
	}
	if n >= s.limits.DevicesPerAccount {
		return s.refuse(admission.Devices, ErrDeviceLimit)
	}
	return nil
}
