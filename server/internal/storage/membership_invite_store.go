package storage

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
)

// C1: membership invitations and join requests (migration 0048).
//
// The invitation link's secret stays in the URL fragment. The app derives a
// locator from it and sends only that; the store keeps SHA-256(locator). A
// request grants nothing. Membership, the sync events and the use count change
// together in DecideJoinRequest, and only for an owner or admin of the target.

var (
	// ErrAlreadyMember: the account already belongs to the target.
	ErrAlreadyMember = errors.New("account already belongs to this group or community")
	// ErrJoinRequestResolved: the request was already decided another way.
	ErrJoinRequestResolved = errors.New("join request was already decided")
	// ErrMembershipInviteUnavailable: the invitation of a request is
	// revoked, expired, used up or its creator may no longer invite.
	ErrMembershipInviteUnavailable = errors.New("invitation is no longer usable")
	// ErrJoinRequestLimit: too many pending requests for the account or target.
	ErrJoinRequestLimit = errors.New("too many pending join requests")
)

const (
	// MaxMembershipInviteLifetime bounds an invitation's expiry.
	MaxMembershipInviteLifetime  = 90 * 24 * time.Hour
	maxActiveInvitesPerTarget    = 50
	maxPendingRequestsPerTarget  = 200
	maxPendingRequestsPerAccount = 20
	maxListedJoinRequests        = 200
	maxListedOwnRequests         = 50
	maxMembershipInviteUses      = 1000
	signingKeyLength             = 32
)

// MembershipTarget names a group (a conversation of kind group) or a community.
type MembershipTarget struct {
	Kind string
	ID   string
}

func (t MembershipTarget) valid() bool {
	return (t.Kind == domain.InviteTargetGroup || t.Kind == domain.InviteTargetCommunity) && t.ID != ""
}

func (t MembershipTarget) columns() (community, conversation sql.NullString) {
	if t.Kind == domain.InviteTargetCommunity {
		return sql.NullString{String: t.ID, Valid: true}, sql.NullString{}
	}
	return sql.NullString{}, sql.NullString{String: t.ID, Valid: true}
}

func targetFromColumns(community, conversation sql.NullString) MembershipTarget {
	if community.Valid {
		return MembershipTarget{Kind: domain.InviteTargetCommunity, ID: community.String}
	}
	return MembershipTarget{Kind: domain.InviteTargetGroup, ID: conversation.String}
}

// validLocator reports whether value is 64 lowercase hex characters, the form
// the app derives from the link secret.
func validLocator(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func hashLocator(locator string) string {
	sum := sha256.Sum256([]byte("veritra/membership-invite/v1/stored-locator\x00" + locator))
	return hex.EncodeToString(sum[:])
}

// memberRoleTx is the account's role in the target. A group target must be a
// conversation of kind group. ErrNotMember when it has no membership.
func memberRoleTx(ctx context.Context, q queryRower, target MembershipTarget, accountID string) (string, error) {
	var role string
	var err error
	if target.Kind == domain.InviteTargetCommunity {
		err = q.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, target.ID, accountID).Scan(&role)
	} else {
		err = q.QueryRowContext(ctx, `SELECT m.role FROM memberships m JOIN conversations c ON c.id = m.conversation_id WHERE m.conversation_id = ? AND m.account_id = ? AND c.kind = 'group'`, target.ID, accountID).Scan(&role)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotMember
	}
	return role, err
}

// inviteAdminRoleTx requires the account to be an owner or admin of the target.
func inviteAdminRoleTx(ctx context.Context, q queryRower, target MembershipTarget, accountID string) error {
	role, err := memberRoleTx(ctx, q, target, accountID)
	if err != nil {
		return err
	}
	if !domain.CanManageInvites(role) {
		return ErrForbidden
	}
	return nil
}

// usableInviteSQL is the SQL form of usableInviteTx for a query that aliases
// membership_invites as i: not revoked or expired, uses left, its creating
// device not revoked, and its creator an active owner or admin of the target. It takes one argument, the current
// time. Counting caps, listing requests and approving use the same test, so a
// request nobody can approve is never listed or counted.
var usableInviteSQL = `(i.revoked_at IS NULL AND i.uses < i.max_uses AND i.expires_at > ?
	AND EXISTS (SELECT 1 FROM accounts ca WHERE ca.id = i.created_by AND ca.deleted_at IS NULL)
	AND EXISTS (SELECT 1 FROM devices cd WHERE cd.id = i.created_by_device_id AND cd.revoked_at IS NULL)
	AND EXISTS (SELECT 1 FROM memberships cm WHERE cm.account_id = i.created_by AND cm.role IN ('` + domain.RoleOwner + `', '` + domain.RoleAdmin + `')
		AND ((i.community_id IS NOT NULL AND cm.community_id = i.community_id) OR (i.conversation_id IS NOT NULL AND cm.conversation_id = i.conversation_id))))`

type inviteRow struct {
	id        string
	target    MembershipTarget
	createdBy string
}

// inviteBindingTx reads what the creating device bound invitation id to.
func inviteBindingTx(ctx context.Context, q queryRower, invite inviteRow) (domain.InviteBinding, error) {
	binding := domain.InviteBinding{TargetKind: invite.target.Kind, TargetID: invite.target.ID, InviterAccountID: invite.createdBy}
	err := q.QueryRowContext(ctx, `SELECT created_by_device_id, creator_signing_key, binding_tag FROM membership_invites WHERE id = ?`, invite.id).
		Scan(&binding.InviterDeviceID, &binding.InviterSigningKey, &binding.Tag)
	return binding, err
}

// usableInviteTx loads the invitation whose where clause matches and returns
// ErrMembershipInviteUnavailable unless it can bring someone in now: not
// revoked or expired, uses left, and its creator an active owner or admin of
// the target.
func usableInviteTx(ctx context.Context, tx *sql.Tx, where string, arg interface{}) (inviteRow, error) {
	var row inviteRow
	var community, conversation sql.NullString
	var maxUses, uses int
	var expires string
	var revoked sql.NullString
	err := tx.QueryRowContext(ctx, `SELECT id, community_id, conversation_id, created_by, max_uses, uses, expires_at, revoked_at FROM membership_invites WHERE `+where, arg).
		Scan(&row.id, &community, &conversation, &row.createdBy, &maxUses, &uses, &expires, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return inviteRow{}, ErrMembershipInviteUnavailable
	}
	if err != nil {
		return inviteRow{}, err
	}
	row.target = targetFromColumns(community, conversation)
	if revoked.Valid || uses >= maxUses || expires <= nowString() {
		return inviteRow{}, ErrMembershipInviteUnavailable
	}
	var active int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, row.createdBy).Scan(&active); err != nil {
		return inviteRow{}, err
	}
	if active == 0 {
		return inviteRow{}, ErrMembershipInviteUnavailable
	}
	var deviceLive int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices d JOIN membership_invites i ON i.created_by_device_id = d.id WHERE i.id = ? AND d.revoked_at IS NULL`, row.id).Scan(&deviceLive); err != nil {
		return inviteRow{}, err
	}
	if deviceLive == 0 {
		return inviteRow{}, ErrMembershipInviteUnavailable
	}
	if err := inviteAdminRoleTx(ctx, tx, row.target, row.createdBy); err != nil {
		if errors.Is(err, ErrNotMember) || errors.Is(err, ErrForbidden) {
			return inviteRow{}, ErrMembershipInviteUnavailable
		}
		return inviteRow{}, err
	}
	// C5: while a community's invitations are paused, none can be used.
	if community.Valid {
		var paused sql.NullString
		if err := tx.QueryRowContext(ctx, `SELECT invites_paused_until FROM communities WHERE id = ?`, community.String).Scan(&paused); err != nil {
			return inviteRow{}, err
		}
		if paused.Valid && parseTime(paused.String).After(time.Now().UTC()) {
			return inviteRow{}, ErrMembershipInviteUnavailable
		}
	}
	return row, nil
}

func isTargetMemberTx(ctx context.Context, q queryRower, target MembershipTarget, accountID string) (bool, error) {
	_, err := memberRoleTx(ctx, q, target, accountID)
	if errors.Is(err, ErrNotMember) {
		return false, nil
	}
	return err == nil, err
}

func targetNameTx(ctx context.Context, q queryRower, target MembershipTarget) (string, error) {
	var name sql.NullString
	var err error
	if target.Kind == domain.InviteTargetCommunity {
		err = q.QueryRowContext(ctx, `SELECT name FROM communities WHERE id = ?`, target.ID).Scan(&name)
	} else {
		err = q.QueryRowContext(ctx, `SELECT title FROM conversations WHERE id = ?`, target.ID).Scan(&name)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return name.String, err
}

// CreateMembershipInviteInput describes a new invitation. Locator is derived
// by the app from the link secret; the secret itself never reaches the server.
//
// CreatedByDeviceID is the session's device. SigningKey is the key the app
// bound into BindingTag; it must equal the device's registered signing key,
// so a tag over any other key is refused here. The server cannot check the
// tag itself: that needs the secret.
type CreateMembershipInviteInput struct {
	Target            MembershipTarget
	CreatedBy         string
	CreatedByDeviceID string
	SigningKey        []byte
	BindingTag        string
	Locator           string
	MaxUses           int
	ExpiresAt         time.Time
}

// CreateMembershipInvite stores an invitation for a group or community the
// actor owns or administers.
func (s *Store) CreateMembershipInvite(ctx context.Context, input CreateMembershipInviteInput) (domain.MembershipInvite, error) {
	if !input.Target.valid() || !validLocator(input.Locator) || !validLocator(input.BindingTag) || input.CreatedByDeviceID == "" || len(input.SigningKey) != signingKeyLength || input.MaxUses < 1 || input.MaxUses > maxMembershipInviteUses {
		return domain.MembershipInvite{}, ErrInvalidInput
	}
	now := time.Now().UTC()
	expires := input.ExpiresAt.UTC()
	if !expires.After(now) || expires.Sub(now) > MaxMembershipInviteLifetime {
		return domain.MembershipInvite{}, ErrInvalidInput
	}
	id, err := domain.NewID("minv")
	if err != nil {
		return domain.MembershipInvite{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.MembershipInvite{}, err
	}
	defer tx.Rollback()
	if err := inviteAdminRoleTx(ctx, tx, input.Target, input.CreatedBy); err != nil {
		return domain.MembershipInvite{}, err
	}
	// The binding names a live device of the creating account, with the
	// signing key the server has on record for it.
	var registered []byte
	err = tx.QueryRowContext(ctx, `SELECT signing_key FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NULL`, input.CreatedByDeviceID, input.CreatedBy).Scan(&registered)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.MembershipInvite{}, ErrInvalidInput
	}
	if err != nil {
		return domain.MembershipInvite{}, err
	}
	if subtle.ConstantTimeCompare(registered, input.SigningKey) != 1 {
		return domain.MembershipInvite{}, ErrInvalidInput
	}
	community, conversation := input.Target.columns()
	active, err := countRows(ctx, tx, `SELECT COUNT(*) FROM membership_invites WHERE community_id IS ? AND conversation_id IS ? AND revoked_at IS NULL AND expires_at > ? AND uses < max_uses`, community, conversation, formatTime(now))
	if err != nil {
		return domain.MembershipInvite{}, err
	}
	if active >= maxActiveInvitesPerTarget {
		return domain.MembershipInvite{}, ErrJoinRequestLimit
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO membership_invites(id, community_id, conversation_id, created_by, created_by_device_id, creator_signing_key, binding_tag, locator_hash, max_uses, expires_at, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, community, conversation, input.CreatedBy, input.CreatedByDeviceID, registered, input.BindingTag, hashLocator(input.Locator), input.MaxUses, formatTime(expires), formatTime(now)); err != nil {
		// A repeated locator: the secret is 256 bits, so this is a client bug or a replay.
		return domain.MembershipInvite{}, ErrInvalidInput
	}
	if err := tx.Commit(); err != nil {
		return domain.MembershipInvite{}, err
	}
	return domain.MembershipInvite{ID: id, TargetKind: input.Target.Kind, TargetID: input.Target.ID, CreatedBy: input.CreatedBy, MaxUses: input.MaxUses, ExpiresAt: expires, CreatedAt: now}, nil
}

// ListMembershipInvites lists the target's active invitations, for its
// owners and admins only. The links themselves are not stored.
func (s *Store) ListMembershipInvites(ctx context.Context, target MembershipTarget, actorAccountID string) ([]domain.MembershipInvite, error) {
	if !target.valid() {
		return nil, ErrInvalidInput
	}
	if err := inviteAdminRoleTx(ctx, s.db, target, actorAccountID); err != nil {
		return nil, err
	}
	community, conversation := target.columns()
	rows, err := s.db.QueryContext(ctx, `SELECT id, created_by, max_uses, uses, expires_at, created_at FROM membership_invites WHERE community_id IS ? AND conversation_id IS ? AND revoked_at IS NULL AND expires_at > ? AND uses < max_uses ORDER BY created_at DESC, id LIMIT ?`, community, conversation, nowString(), maxActiveInvitesPerTarget)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	invites := make([]domain.MembershipInvite, 0)
	for rows.Next() {
		invite := domain.MembershipInvite{TargetKind: target.Kind, TargetID: target.ID}
		var expires, created string
		if err := rows.Scan(&invite.ID, &invite.CreatedBy, &invite.MaxUses, &invite.Uses, &expires, &created); err != nil {
			return nil, err
		}
		invite.ExpiresAt = parseTime(expires)
		invite.CreatedAt = parseTime(created)
		invites = append(invites, invite)
	}
	return invites, rows.Err()
}

// RevokeMembershipInvite revokes an invitation and cancels its pending
// requests. The creator or an owner or admin of the target may do it; anyone
// else gets ErrNotFound, so ids cannot be probed.
func (s *Store) RevokeMembershipInvite(ctx context.Context, actorAccountID, inviteID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var community, conversation sql.NullString
	var createdBy string
	err = tx.QueryRowContext(ctx, `SELECT community_id, conversation_id, created_by FROM membership_invites WHERE id = ?`, inviteID).Scan(&community, &conversation, &createdBy)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	target := targetFromColumns(community, conversation)
	if err := inviteAdminRoleTx(ctx, tx, target, actorAccountID); err != nil {
		denied := errors.Is(err, ErrNotMember) || errors.Is(err, ErrForbidden)
		switch {
		case !denied:
			return err
		case createdBy != actorAccountID:
			return ErrNotFound
		}
		// A creator who lost the role may still withdraw their own link.
	}
	now := nowString()
	if err := revokeInviteTx(ctx, tx, `id = ?`, now, inviteID); err != nil {
		return err
	}
	return tx.Commit()
}

// revokeInviteTx revokes the invitations matching where and cancels their
// pending requests.
func revokeInviteTx(ctx context.Context, tx *sql.Tx, where, now string, args ...interface{}) error {
	if _, err := tx.ExecContext(ctx, `UPDATE membership_join_requests SET status = 'cancelled', decided_at = ? WHERE status = 'pending' AND invite_id IN (SELECT id FROM membership_invites WHERE revoked_at IS NULL AND (`+where+`))`, append([]interface{}{now}, args...)...); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `UPDATE membership_invites SET revoked_at = COALESCE(revoked_at, ?) WHERE `+where, append([]interface{}{now}, args...)...)
	return err
}

// PreviewMembershipInvite shows a signed-in holder of the link what it
// leads to. Every unusable or unknown locator is ErrNotFound.
func (s *Store) PreviewMembershipInvite(ctx context.Context, accountID, locator string) (domain.MembershipInvitePreview, error) {
	if !validLocator(locator) {
		return domain.MembershipInvitePreview{}, ErrNotFound
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return domain.MembershipInvitePreview{}, err
	}
	defer tx.Rollback()
	invite, err := usableInviteTx(ctx, tx, `locator_hash = ?`, hashLocator(locator))
	if err != nil {
		return domain.MembershipInvitePreview{}, mapUnavailableToNotFound(err)
	}
	if blocked, err := blockedPairTx(ctx, tx, accountID, invite.createdBy); err != nil {
		return domain.MembershipInvitePreview{}, err
	} else if blocked {
		return domain.MembershipInvitePreview{}, ErrNotFound
	}
	name, err := targetNameTx(ctx, tx, invite.target)
	if err != nil {
		return domain.MembershipInvitePreview{}, err
	}
	var inviter, expires string
	if err := tx.QueryRowContext(ctx, `SELECT a.username, i.expires_at FROM membership_invites i JOIN accounts a ON a.id = i.created_by WHERE i.id = ?`, invite.id).Scan(&inviter, &expires); err != nil {
		return domain.MembershipInvitePreview{}, err
	}
	member, err := isTargetMemberTx(ctx, tx, invite.target, accountID)
	if err != nil {
		return domain.MembershipInvitePreview{}, err
	}
	binding, err := inviteBindingTx(ctx, tx, invite)
	if err != nil {
		return domain.MembershipInvitePreview{}, err
	}
	return domain.MembershipInvitePreview{TargetKind: invite.target.Kind, TargetName: name, InviterUsername: inviter, ExpiresAt: parseTime(expires), AlreadyMember: member, Binding: binding}, nil
}

func mapUnavailableToNotFound(err error) error {
	if errors.Is(err, ErrMembershipInviteUnavailable) {
		return ErrNotFound
	}
	return err
}

func blockedPairTx(ctx context.Context, q queryRower, a, b string) (bool, error) {
	n, err := countRows(ctx, q, `SELECT COUNT(*) FROM account_blocks WHERE (blocker_account_id = ? AND blocked_account_id = ?) OR (blocker_account_id = ? AND blocked_account_id = ?)`, a, b, b, a)
	return n > 0, err
}

// RequestToJoin files a pending request for the invitation behind locator.
// created is false when the account already had a pending request for the
// target, which is returned unchanged. Nothing is granted until approval.
func (s *Store) RequestToJoin(ctx context.Context, accountID, locator string) (request domain.JoinRequest, created bool, err error) {
	if !validLocator(locator) {
		return domain.JoinRequest{}, false, ErrNotFound
	}
	id, err := domain.NewID("jreq")
	if err != nil {
		return domain.JoinRequest{}, false, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.JoinRequest{}, false, err
	}
	defer tx.Rollback()
	invite, err := usableInviteTx(ctx, tx, `locator_hash = ?`, hashLocator(locator))
	if err != nil {
		return domain.JoinRequest{}, false, mapUnavailableToNotFound(err)
	}
	// A block between the requester and the inviter looks like any other
	// unusable link.
	if blocked, err := blockedPairTx(ctx, tx, accountID, invite.createdBy); err != nil {
		return domain.JoinRequest{}, false, err
	} else if blocked {
		return domain.JoinRequest{}, false, ErrNotFound
	}
	member, err := isTargetMemberTx(ctx, tx, invite.target, accountID)
	if err != nil {
		return domain.JoinRequest{}, false, err
	}
	if member {
		return domain.JoinRequest{}, false, ErrAlreadyMember
	}
	// C5: a banned account's request looks like any other unusable link.
	if invite.target.Kind == domain.InviteTargetCommunity {
		if banned, err := communityBannedTx(ctx, tx, invite.target.ID, accountID); err != nil {
			return domain.JoinRequest{}, false, err
		} else if banned {
			return domain.JoinRequest{}, false, ErrNotFound
		}
	}
	binding, err := inviteBindingTx(ctx, tx, invite)
	if err != nil {
		return domain.JoinRequest{}, false, err
	}
	community, conversation := invite.target.columns()
	var existingID, existingInvite string
	var existingCreated string
	err = tx.QueryRowContext(ctx, `SELECT id, invite_id, created_at FROM membership_join_requests WHERE account_id = ? AND status = 'pending' AND community_id IS ? AND conversation_id IS ?`, accountID, community, conversation).Scan(&existingID, &existingInvite, &existingCreated)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return domain.JoinRequest{}, false, err
	}
	if err == nil {
		// A pending request whose own invitation is no longer usable is
		// replaced; otherwise the same request stands.
		if _, usableErr := usableInviteTx(ctx, tx, `id = ?`, existingInvite); usableErr == nil {
			return domain.JoinRequest{ID: existingID, TargetKind: invite.target.Kind, Status: domain.JoinRequestPending, CreatedAt: parseTime(existingCreated), Binding: &binding}, false, nil
		} else if !errors.Is(usableErr, ErrMembershipInviteUnavailable) {
			return domain.JoinRequest{}, false, usableErr
		}
		if _, err := tx.ExecContext(ctx, `UPDATE membership_join_requests SET status = 'cancelled', decided_at = ? WHERE id = ? AND status = 'pending'`, nowString(), existingID); err != nil {
			return domain.JoinRequest{}, false, err
		}
	}
	// Both caps count only requests that could still be approved, so dead
	// ones (invitation used up, expired, revoked, creator demoted) never
	// block a new request.
	now := time.Now().UTC()
	own, err := countRows(ctx, tx, `SELECT COUNT(*) FROM membership_join_requests r JOIN membership_invites i ON i.id = r.invite_id WHERE r.account_id = ? AND r.status = 'pending' AND `+usableInviteSQL, accountID, formatTime(now))
	if err != nil {
		return domain.JoinRequest{}, false, err
	}
	forTarget, err := countRows(ctx, tx, `SELECT COUNT(*) FROM membership_join_requests r JOIN membership_invites i ON i.id = r.invite_id JOIN accounts ra ON ra.id = r.account_id AND ra.deleted_at IS NULL WHERE r.community_id IS ? AND r.conversation_id IS ? AND r.status = 'pending' AND `+usableInviteSQL, community, conversation, formatTime(now))
	if err != nil {
		return domain.JoinRequest{}, false, err
	}
	if own >= maxPendingRequestsPerAccount || forTarget >= maxPendingRequestsPerTarget {
		return domain.JoinRequest{}, false, ErrJoinRequestLimit
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO membership_join_requests(id, invite_id, community_id, conversation_id, account_id, status, created_at) VALUES(?, ?, ?, ?, ?, 'pending', ?)`, id, invite.id, community, conversation, accountID, formatTime(now)); err != nil {
		return domain.JoinRequest{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return domain.JoinRequest{}, false, err
	}
	return domain.JoinRequest{ID: id, TargetKind: invite.target.Kind, Status: domain.JoinRequestPending, CreatedAt: now, Binding: &binding}, true, nil
}

// ListJoinRequests lists the pending requests for a target, with usernames,
// for its owners and admins. A request whose invitation can no longer be used
// (revoked, expired, used up, creator no longer owner or admin) is left out: approving it would fail.
func (s *Store) ListJoinRequests(ctx context.Context, target MembershipTarget, actorAccountID string) ([]domain.JoinRequest, error) {
	if !target.valid() {
		return nil, ErrInvalidInput
	}
	if err := inviteAdminRoleTx(ctx, s.db, target, actorAccountID); err != nil {
		return nil, err
	}
	community, conversation := target.columns()
	rows, err := s.db.QueryContext(ctx, `
		SELECT r.id, r.account_id, a.username, r.created_at
		FROM membership_join_requests r
		JOIN membership_invites i ON i.id = r.invite_id
		JOIN accounts a ON a.id = r.account_id AND a.deleted_at IS NULL
		WHERE r.community_id IS ? AND r.conversation_id IS ? AND r.status = 'pending'
		  AND `+usableInviteSQL+`
		ORDER BY r.created_at, r.id
		LIMIT ?`, community, conversation, nowString(), maxListedJoinRequests)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	requests := make([]domain.JoinRequest, 0)
	for rows.Next() {
		request := domain.JoinRequest{TargetKind: target.Kind, TargetID: target.ID, Status: domain.JoinRequestPending}
		var created string
		if err := rows.Scan(&request.ID, &request.AccountID, &request.Username, &created); err != nil {
			return nil, err
		}
		request.CreatedAt = parseTime(created)
		requests = append(requests, request)
	}
	return requests, rows.Err()
}

// ListOwnJoinRequests lists the account's most recent requests, so the app
// can show waiting, approved and rejected ones. A pending request whose
// invitation can no longer be used reads as cancelled, not waiting.
func (s *Store) ListOwnJoinRequests(ctx context.Context, accountID string) ([]domain.JoinRequest, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT r.id, r.community_id, r.conversation_id,
		       CASE WHEN r.status = 'pending' AND NOT `+usableInviteSQL+` THEN 'cancelled' ELSE r.status END,
		       r.created_at, r.decided_at, COALESCE(c.name, g.title, '')
		FROM membership_join_requests r
		JOIN membership_invites i ON i.id = r.invite_id
		LEFT JOIN communities c ON c.id = r.community_id
		LEFT JOIN conversations g ON g.id = r.conversation_id
		WHERE r.account_id = ?
		ORDER BY r.created_at DESC, r.id
		LIMIT ?`, nowString(), accountID, maxListedOwnRequests)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	requests := make([]domain.JoinRequest, 0)
	for rows.Next() {
		var request domain.JoinRequest
		var community, conversation, decided sql.NullString
		var created string
		if err := rows.Scan(&request.ID, &community, &conversation, &request.Status, &created, &decided, &request.TargetName); err != nil {
			return nil, err
		}
		target := targetFromColumns(community, conversation)
		request.TargetKind = target.Kind
		// The id is shown only once the request was approved, when the
		// requester is a member and sees the target anyway.
		if request.Status == domain.JoinRequestApproved {
			request.TargetID = target.ID
		}
		request.CreatedAt = parseTime(created)
		request.DecidedAt = parseOptionalTime(decided)
		requests = append(requests, request)
	}
	return requests, rows.Err()
}

// CancelJoinRequest withdraws the account's own pending request.
func (s *Store) CancelJoinRequest(ctx context.Context, accountID, requestID string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE membership_join_requests SET status = 'cancelled', decided_at = ? WHERE id = ? AND account_id = ? AND status = 'pending'`, nowString(), requestID, accountID)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		var status string
		err := s.db.QueryRowContext(ctx, `SELECT status FROM membership_join_requests WHERE id = ? AND account_id = ?`, requestID, accountID).Scan(&status)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if status != domain.JoinRequestCancelled {
			return ErrJoinRequestResolved
		}
	}
	return nil
}

// JoinDecision is the outcome of DecideJoinRequest. For an approved group
// request, ConversationID and EventID name the membership event to publish;
// for a community, EventIDs holds one event per channel conversation.
type JoinDecision struct {
	Request        domain.JoinRequest
	Changed        bool
	ConversationID string
	EventID        int64
	EventIDs       []int64
}

// DecideJoinRequest approves or rejects a pending request for an owner or
// admin of its target. Approval joins the requester as a member through the
// same rules as adding one by hand (blocks, limits, admission) and counts the
// use, all in one transaction. Repeating the same decision changes nothing and
// succeeds; the opposite one is ErrJoinRequestResolved.
func (s *Store) DecideJoinRequest(ctx context.Context, actorAccountID, requestID string, approve bool) (JoinDecision, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return JoinDecision{}, err
	}
	defer tx.Rollback()
	var inviteID, requester, status, created string
	var community, conversation sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT invite_id, community_id, conversation_id, account_id, status, created_at FROM membership_join_requests WHERE id = ?`, requestID).Scan(&inviteID, &community, &conversation, &requester, &status, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return JoinDecision{}, ErrNotFound
	}
	if err != nil {
		return JoinDecision{}, err
	}
	target := targetFromColumns(community, conversation)
	// Someone who cannot administer the target must not learn that a request exists.
	if err := inviteAdminRoleTx(ctx, tx, target, actorAccountID); err != nil {
		if errors.Is(err, ErrNotMember) || errors.Is(err, ErrForbidden) {
			return JoinDecision{}, ErrNotFound
		}
		return JoinDecision{}, err
	}
	want := domain.JoinRequestRejected
	if approve {
		want = domain.JoinRequestApproved
	}
	request := domain.JoinRequest{ID: requestID, TargetKind: target.Kind, TargetID: target.ID, AccountID: requester, Status: status, CreatedAt: parseTime(created)}
	if status != domain.JoinRequestPending {
		if status == want {
			return JoinDecision{Request: request}, nil
		}
		return JoinDecision{}, ErrJoinRequestResolved
	}
	if approve {
		if _, err := usableInviteTx(ctx, tx, `id = ?`, inviteID); err != nil {
			return JoinDecision{}, err
		}
		var active int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, requester).Scan(&active); err != nil {
			return JoinDecision{}, err
		}
		if active == 0 {
			return JoinDecision{}, ErrNotFound
		}
		if member, err := isTargetMemberTx(ctx, tx, target, requester); err != nil {
			return JoinDecision{}, err
		} else if member {
			return JoinDecision{}, ErrAlreadyMember
		}
	}
	now := nowString()
	result, err := tx.ExecContext(ctx, `UPDATE membership_join_requests SET status = ?, decided_by = ?, decided_at = ? WHERE id = ? AND status = 'pending'`, want, actorAccountID, now, requestID)
	if err != nil {
		return JoinDecision{}, err
	}
	if n, err := result.RowsAffected(); err != nil {
		return JoinDecision{}, err
	} else if n != 1 {
		return JoinDecision{}, ErrJoinRequestResolved
	}
	decision := JoinDecision{Changed: true}
	if approve {
		result, err := tx.ExecContext(ctx, `UPDATE membership_invites SET uses = uses + 1 WHERE id = ? AND uses < max_uses`, inviteID)
		if err != nil {
			return JoinDecision{}, err
		}
		if n, err := result.RowsAffected(); err != nil {
			return JoinDecision{}, err
		} else if n != 1 {
			return JoinDecision{}, ErrMembershipInviteUnavailable
		}
		// The last use is gone: the other requests on this link can never be
		// approved, so close them instead of leaving them pending.
		if _, err := tx.ExecContext(ctx, `UPDATE membership_join_requests SET status = 'cancelled', decided_at = ? WHERE invite_id = ? AND status = 'pending' AND EXISTS (SELECT 1 FROM membership_invites WHERE id = ? AND uses >= max_uses)`, now, inviteID, inviteID); err != nil {
			return JoinDecision{}, err
		}
		if target.Kind == domain.InviteTargetCommunity {
			ids, err := s.manageCommunityMemberTx(ctx, tx, target.ID, actorAccountID, requester, domain.RoleMember)
			if err != nil {
				return JoinDecision{}, err
			}
			decision.EventIDs = ids
		} else {
			eventID, err := s.manageConversationMemberTx(ctx, tx, target.ID, actorAccountID, requester, domain.RoleMember)
			if err != nil {
				return JoinDecision{}, err
			}
			decision.ConversationID = target.ID
			decision.EventID = eventID
		}
	}
	if err := tx.Commit(); err != nil {
		return JoinDecision{}, err
	}
	request.Status = want
	decided := parseTime(now)
	request.DecidedAt = &decided
	decision.Request = request
	return decision, nil
}

// cancelPendingJoinRequestsTx closes the account's pending requests for a
// target it has just joined by another route, so no admin is offered an
// approval that would fail with already_member.
func cancelPendingJoinRequestsTx(ctx context.Context, tx *sql.Tx, target MembershipTarget, accountID string) error {
	community, conversation := target.columns()
	_, err := tx.ExecContext(ctx, `UPDATE membership_join_requests SET status = 'cancelled', decided_at = ? WHERE account_id = ? AND status = 'pending' AND community_id IS ? AND conversation_id IS ?`, nowString(), accountID, community, conversation)
	return err
}
