package storage

import (
	"context"
	"database/sql"
	"errors"
	"sort"
	"time"

	"private-messenger/server/internal/domain"
)

// C4 server succession (docs/designs/C4-custom-roles.md, "Server
// succession"; the rule is domain/succession.go). Apps take ownership from
// the signed role record and never read these rows (D80); this moves the
// server's owner row after a won election so the server's own route checks
// follow, and only when an active owner could not be the one losing it.

// SuccessionStatus says what a succession ask did.
type SuccessionStatus string

const (
	// SuccessionMoved: the candidate is now the server's owner.
	SuccessionMoved SuccessionStatus = "moved"
	// SuccessionRecorded: the ask is kept; the rule does not hold yet.
	SuccessionRecorded SuccessionStatus = "recorded"
)

// touchMembershipActivityTx records that accountID sent an envelope or an MLS
// commit in conversationID at now: the UTC day only (L2-2), written at most
// once a day per membership.
func touchMembershipActivityTx(ctx context.Context, tx *sql.Tx, conversationID, accountID string, now time.Time) error {
	day := formatTime(domain.ActivityDay(now))
	_, err := tx.ExecContext(ctx, `UPDATE memberships SET last_active_at = ? WHERE conversation_id = ? AND account_id = ? AND (last_active_at IS NULL OR last_active_at < ?)`, day, conversationID, accountID, day)
	return err
}

// clearSuccessionAsksTx drops every ask of a scope: ownership has moved, so
// asks made for the previous owner's absence no longer apply.
func clearSuccessionAsksTx(ctx context.Context, tx *sql.Tx, scope successionScope) error {
	_, err := tx.ExecContext(ctx, `DELETE FROM owner_succession_requests WHERE `+scope.column()+` = ?`, scope.id)
	return err
}

type successionScope struct {
	community bool
	id        string
}

func (s successionScope) column() string {
	if s.community {
		return "community_id"
	}
	return "conversation_id"
}

type successionMember struct {
	accountID  string
	role       string
	createdAt  string
	lastActive *time.Time
}

// RequestConversationSuccession records callerAccountID's ask that
// candidateAccountID become the owner of a group (kind "group"; a community's
// conversations follow the community, see RequestCommunitySuccession) and
// moves the owner row when the rule holds. The current owner's own ask is a
// transfer, as through the member route.
func (s *Store) RequestConversationSuccession(ctx context.Context, conversationID, callerAccountID, candidateAccountID string) (SuccessionStatus, []int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", nil, err
	}
	defer tx.Rollback()
	var kind string
	if err := tx.QueryRowContext(ctx, `SELECT kind FROM conversations WHERE id = ?`, conversationID).Scan(&kind); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", nil, ErrNotFound
		}
		return "", nil, err
	}
	scope := successionScope{id: conversationID}
	status, events, err := s.requestSuccessionTx(ctx, tx, scope, kind == "group", callerAccountID, candidateAccountID)
	if err != nil {
		return "", nil, err
	}
	return status, events, tx.Commit()
}

// RequestCommunitySuccession is RequestConversationSuccession for a
// community: its membership rows, and its join conversations and private
// channels through applyCommunityRoleTx.
func (s *Store) RequestCommunitySuccession(ctx context.Context, communityID, callerAccountID, candidateAccountID string) (SuccessionStatus, []int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", nil, err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM communities WHERE id = ?`, communityID).Scan(&exists); err != nil {
		return "", nil, err
	}
	if exists == 0 {
		return "", nil, ErrNotFound
	}
	scope := successionScope{community: true, id: communityID}
	status, events, err := s.requestSuccessionTx(ctx, tx, scope, true, callerAccountID, candidateAccountID)
	if err != nil {
		return "", nil, err
	}
	return status, events, tx.Commit()
}

func (s *Store) requestSuccessionTx(ctx context.Context, tx *sql.Tx, scope successionScope, allowed bool, callerAccountID, candidateAccountID string) (SuccessionStatus, []int64, error) {
	members, err := successionMembersTx(ctx, tx, scope)
	if err != nil {
		return "", nil, err
	}
	byID := make(map[string]successionMember, len(members))
	var owner *successionMember
	for i := range members {
		byID[members[i].accountID] = members[i]
		if members[i].role == domain.RoleOwner {
			owner = &members[i]
		}
	}
	caller, ok := byID[callerAccountID]
	if !ok {
		return "", nil, ErrNotMember
	}
	// A DM has no owner to succeed, and a community's conversations follow
	// the community's own rows.
	if !allowed {
		return "", nil, ErrForbidden
	}
	candidate, ok := byID[candidateAccountID]
	if !ok || candidate.role == domain.RoleOwner {
		return "", nil, ErrForbidden
	}
	if caller.role == domain.RoleOwner {
		// The owner's app saw it lose a won election (or hands over itself):
		// a transfer, under the transfer's rule (to a current admin).
		if candidate.role != domain.RoleAdmin {
			return "", nil, ErrForbidden
		}
		events, err := s.moveOwnerTx(ctx, tx, scope, owner, candidateAccountID)
		if err != nil {
			return "", nil, err
		}
		return SuccessionMoved, events, nil
	}
	admins := 0
	for _, m := range members {
		if m.role == domain.RoleAdmin {
			admins++
		}
	}
	if admins > 0 {
		// Only admins ask, and only for an admin (as a transfer is to one).
		if caller.role != domain.RoleAdmin || candidate.role != domain.RoleAdmin {
			return "", nil, ErrForbidden
		}
	} else if callerAccountID != candidateAccountID || longestServing(members) != candidateAccountID {
		// No admin: only the longest-serving member, for itself (D81).
		return "", nil, ErrForbidden
	}
	now := time.Now().UTC()
	if _, err := tx.ExecContext(ctx, `DELETE FROM owner_succession_requests WHERE account_id = ? AND `+scope.column()+` = ?`, callerAccountID, scope.id); err != nil {
		return "", nil, err
	}
	conversationID, communityID := sql.NullString{}, sql.NullString{}
	if scope.community {
		communityID = sql.NullString{String: scope.id, Valid: true}
	} else {
		conversationID = sql.NullString{String: scope.id, Valid: true}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO owner_succession_requests(account_id, conversation_id, community_id, candidate_account_id, created_at) VALUES(?, ?, ?, ?, ?)`, callerAccountID, conversationID, communityID, candidateAccountID, formatTime(now)); err != nil {
		return "", nil, err
	}
	var lastActive *time.Time
	if owner != nil {
		lastActive, err = ownerLastActiveTx(ctx, tx, scope, *owner)
		if err != nil {
			return "", nil, err
		}
	}
	if !domain.OwnerQuiet(lastActive, now) {
		return SuccessionRecorded, nil, nil
	}
	if admins > 0 {
		asks, err := countSuccessionAsksTx(ctx, tx, scope, candidateAccountID, lastActive)
		if err != nil {
			return "", nil, err
		}
		if !domain.SuccessionQuorum(asks, admins) {
			return SuccessionRecorded, nil, nil
		}
	}
	events, err := s.moveOwnerTx(ctx, tx, scope, owner, candidateAccountID)
	if err != nil {
		return "", nil, err
	}
	return SuccessionMoved, events, nil
}

// successionMembersTx lists the scope's members whose accounts are not
// deleted, in membership order.
func successionMembersTx(ctx context.Context, tx *sql.Tx, scope successionScope) ([]successionMember, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT m.account_id, m.role, m.created_at, m.last_active_at
		FROM memberships m JOIN accounts a ON a.id = m.account_id
		WHERE m.`+scope.column()+` = ? AND a.deleted_at IS NULL
		ORDER BY m.created_at, m.account_id`, scope.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var members []successionMember
	for rows.Next() {
		var m successionMember
		var last sql.NullString
		if err := rows.Scan(&m.accountID, &m.role, &m.createdAt, &last); err != nil {
			return nil, err
		}
		if last.Valid {
			t := parseTime(last.String)
			m.lastActive = &t
		}
		members = append(members, m)
	}
	return members, rows.Err()
}

// longestServing is the non-owner member with the oldest membership, then
// the smallest account id; "" when there is none.
func longestServing(members []successionMember) string {
	var others []successionMember
	for _, m := range members {
		if m.role != domain.RoleOwner {
			others = append(others, m)
		}
	}
	if len(others) == 0 {
		return ""
	}
	sort.SliceStable(others, func(i, j int) bool {
		if others[i].createdAt != others[j].createdAt {
			return others[i].createdAt < others[j].createdAt
		}
		return others[i].accountID < others[j].accountID
	})
	return others[0].accountID
}

// ownerLastActiveTx is the owner's last recorded activity day in the scope:
// its row, or for a community the latest of its rows in the community's
// conversations. A row with no activity counts from its created_at.
func ownerLastActiveTx(ctx context.Context, tx *sql.Tx, scope successionScope, owner successionMember) (*time.Time, error) {
	last := owner.lastActive
	if last == nil {
		t := domain.ActivityDay(parseTime(owner.createdAt))
		last = &t
	}
	if !scope.community {
		return last, nil
	}
	rows, err := tx.QueryContext(ctx, `
		SELECT COALESCE(m.last_active_at, m.created_at)
		FROM memberships m JOIN conversations c ON c.id = m.conversation_id
		WHERE m.account_id = ? AND c.community_id = ?`, owner.accountID, scope.id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			return nil, err
		}
		t := domain.ActivityDay(parseTime(value))
		if t.After(*last) {
			last = &t
		}
	}
	return last, rows.Err()
}

// countSuccessionAsksTx counts asks for candidate from the scope's current
// admins made after the owner's last activity day.
func countSuccessionAsksTx(ctx context.Context, tx *sql.Tx, scope successionScope, candidateAccountID string, lastActive *time.Time) (int, error) {
	since := ""
	if lastActive != nil {
		since = formatTime(domain.ActivityEnd(*lastActive))
	}
	var n int
	err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM owner_succession_requests r
		JOIN memberships m ON m.account_id = r.account_id AND m.`+scope.column()+` = r.`+scope.column()+`
		JOIN accounts a ON a.id = r.account_id AND a.deleted_at IS NULL
		WHERE r.`+scope.column()+` = ? AND r.candidate_account_id = ? AND m.role = ? AND r.created_at >= ?`,
		scope.id, candidateAccountID, domain.RoleAdmin, since).Scan(&n)
	return n, err
}

// moveOwnerTx makes candidate the owner and the previous owner (if any) an
// admin, writes the events the member routes write, clears the scope's asks
// and records the new owner as active today (taking ownership is activity,
// so its tenure does not start already quiet).
func (s *Store) moveOwnerTx(ctx context.Context, tx *sql.Tx, scope successionScope, owner *successionMember, candidateAccountID string) ([]int64, error) {
	var events []int64
	if scope.community {
		// The one-owner index needs the old owner to step down first.
		if owner != nil {
			first, err := s.applyCommunityRoleTx(ctx, tx, scope.id, owner.accountID, domain.RoleAdmin)
			if err != nil {
				return nil, err
			}
			events = append(events, first...)
		}
		second, err := s.applyCommunityRoleTx(ctx, tx, scope.id, candidateAccountID, domain.RoleOwner)
		if err != nil {
			return nil, err
		}
		events = append(events, second...)
	} else {
		createdAt := nowString()
		if owner != nil {
			if _, err := tx.ExecContext(ctx, `UPDATE memberships SET role = ? WHERE conversation_id = ? AND account_id = ?`, domain.RoleAdmin, scope.id, owner.accountID); err != nil {
				return nil, err
			}
			id, err := insertSyncEvent(ctx, tx, "membership.updated", nil, scope.id, map[string]string{"conversation_id": scope.id, "account_id": owner.accountID, "role": domain.RoleAdmin, "mls_coordination": "pending"}, createdAt)
			if err != nil {
				return nil, err
			}
			events = append(events, id)
		}
		if _, err := tx.ExecContext(ctx, `UPDATE memberships SET role = ? WHERE conversation_id = ? AND account_id = ?`, domain.RoleOwner, scope.id, candidateAccountID); err != nil {
			return nil, err
		}
		id, err := insertSyncEvent(ctx, tx, "membership.updated", nil, scope.id, map[string]string{"conversation_id": scope.id, "account_id": candidateAccountID, "role": domain.RoleOwner, "mls_coordination": "pending"}, createdAt)
		if err != nil {
			return nil, err
		}
		events = append(events, id)
	}
	if err := markNewOwnerActiveTx(ctx, tx, scope, candidateAccountID); err != nil {
		return nil, err
	}
	return events, nil
}

// markNewOwnerActiveTx clears the scope's asks and records the new owner as
// active today. Every way ownership moves (transfer or succession) calls it.
func markNewOwnerActiveTx(ctx context.Context, tx *sql.Tx, scope successionScope, ownerAccountID string) error {
	if err := clearSuccessionAsksTx(ctx, tx, scope); err != nil {
		return err
	}
	day := formatTime(domain.ActivityDay(time.Now()))
	_, err := tx.ExecContext(ctx, `UPDATE memberships SET last_active_at = ? WHERE account_id = ? AND `+scope.column()+` = ?`, day, ownerAccountID, scope.id)
	return err
}
