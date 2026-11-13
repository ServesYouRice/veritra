package storage

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/franking"
)

// C6 reports (docs/designs/C6-reports-franking.md). The server routes opaque
// ciphertext: it never opens a sealed report and never stores the reported
// text. Since D95 it does not even learn which message a report is about: the
// envelope id, the revealed text and the franking key are all inside the
// sealed body, so the server records only where a copy goes, who filed it and
// when.

const (
	// MaxSealedReportBytes is the Rust core's largest sealed report
	// (crypto/rust/src/report.rs MAX_SEALED_BYTES).
	MaxSealedReportBytes = 4 + 32 + 256*1024 + 16
	// MinSealedReportBytes is the smallest valid one: magic, enc, one byte, tag.
	MinSealedReportBytes = 4 + 32 + 1 + 16

	sealedReportMagic = "VRP1"

	// maxReportsPerReporterPerDay and maxReportsPerInbox bound what reporting
	// can store (open item 6: rate limits only, no automatic action). The
	// first counts reports (one report is one copy per owner), the second
	// copies held by one inbox.
	maxReportsPerReporterPerDay = 20
	maxReportsPerInbox          = 2000
	// maxReportCopies bounds the copies of one report: one per instance owner
	// with a published key.
	maxReportCopies = 64

	// ReportRetention is how long a report is kept if nobody dismisses it
	// (D95): a recipient dismissing its copy removes that copy at once, and
	// the sweeper removes every copy this long after it was filed.
	ReportRetention = 90 * 24 * time.Hour

	minReportIDBytes = 16
)

var (
	// ErrReportInboxUnavailable: no report key is published for the inbox.
	ErrReportInboxUnavailable = errors.New("no report key is published for this inbox")
	// ErrReportInboxChanged: the copies do not match the inbox's current
	// recipients and keys (a key rotated, an owner published or left).
	ErrReportInboxChanged = errors.New("report inbox key changed")
	// ErrReportDuplicate: this reporter already filed a report with this id.
	ErrReportDuplicate = errors.New("report already filed by this account")
	// ErrReportLimit: the reporter or the inbox holds too many reports.
	ErrReportLimit = errors.New("too many reports")
)

// ReportRecipient is one inbox key a copy of a report is sealed to.
type ReportRecipient struct {
	InboxID   string    `json:"inbox_id"`
	PublicKey []byte    `json:"public_key"`
	KeyRev    int64     `json:"key_rev"`
	UpdatedAt time.Time `json:"updated_at"`
}

// ReportInbox is where a conversation's reports go and the keys to seal to:
// one recipient per instance owner that has published a key, or the
// community's moderator inbox.
type ReportInbox struct {
	Kind       string            `json:"inbox_kind"`
	Recipients []ReportRecipient `json:"recipients"`
}

// Report is one stored copy of a filed report. Sealed is ciphertext; the
// server knows nothing else about the message.
type Report struct {
	ID                 string    `json:"id"`
	ReportID           string    `json:"report_id"`
	InboxKind          string    `json:"inbox_kind"`
	InboxID            string    `json:"inbox_id"`
	KeyRev             int64     `json:"key_rev"`
	RecipientPublicKey []byte    `json:"recipient_public_key"`
	ConversationID     string    `json:"conversation_id"`
	ReporterAccountID  string    `json:"reporter_account_id"`
	Sealed             []byte    `json:"sealed,omitempty"`
	CreatedAt          time.Time `json:"created_at"`
}

// SetInstanceReportKey publishes the calling owner's report public key. Only
// an active owner may, and each owner publishes their own (D95: one sealed
// copy per owner). Publishing the same key again changes nothing; a
// different key raises key_rev, which reports sealed to the old key refuse.
func (s *Store) SetInstanceReportKey(ctx context.Context, accountID string, publicKey []byte) (ReportRecipient, error) {
	if len(publicKey) != franking.PublicKeySize {
		return ReportRecipient{}, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ReportRecipient{}, err
	}
	defer tx.Rollback()
	var role string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM accounts WHERE id = ? AND status = 'active' AND deleted_at IS NULL`, accountID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ReportRecipient{}, ErrForbidden
		}
		return ReportRecipient{}, err
	}
	if role != domain.RoleOwner {
		return ReportRecipient{}, ErrForbidden
	}
	var current []byte
	var rev int64
	var updated string
	err = tx.QueryRowContext(ctx, `SELECT public_key, key_rev, updated_at FROM report_inbox_keys WHERE inbox_kind = ? AND inbox_id = ?`, franking.InboxInstanceOwner, accountID).Scan(&current, &rev, &updated)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		rev = 1
	case err != nil:
		return ReportRecipient{}, err
	case bytes.Equal(current, publicKey):
		return ReportRecipient{InboxID: accountID, PublicKey: current, KeyRev: rev, UpdatedAt: parseTime(updated)}, nil
	default:
		rev++
	}
	now := nowString()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO report_inbox_keys(inbox_kind, inbox_id, public_key, key_rev, set_by_account_id, updated_at)
		VALUES(?, ?, ?, ?, ?, ?)
		ON CONFLICT(inbox_kind, inbox_id) DO UPDATE SET public_key = excluded.public_key, key_rev = excluded.key_rev, set_by_account_id = excluded.set_by_account_id, updated_at = excluded.updated_at`,
		franking.InboxInstanceOwner, accountID, publicKey, rev, accountID, now); err != nil {
		return ReportRecipient{}, err
	}
	if err := tx.Commit(); err != nil {
		return ReportRecipient{}, err
	}
	return ReportRecipient{InboxID: accountID, PublicKey: publicKey, KeyRev: rev, UpdatedAt: parseTime(now)}, nil
}

// SetCommunityReportKey publishes accountID's own report public key as its
// moderator inbox in communityID (C6, one sealed copy per moderator). Any
// active member may publish one: whether reports are sealed to it is the
// reporter's app's decision from the verified role record (C4). The same key
// may serve several communities and the owner inbox; the aad binds each.
func (s *Store) SetCommunityReportKey(ctx context.Context, communityID, accountID string, publicKey []byte) (ReportRecipient, error) {
	if len(publicKey) != franking.PublicKeySize || communityID == "" || accountID == "" {
		return ReportRecipient{}, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ReportRecipient{}, err
	}
	defer tx.Rollback()
	var n int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM memberships m JOIN accounts a ON a.id = m.account_id
		WHERE m.community_id = ? AND m.account_id = ? AND a.status = 'active' AND a.deleted_at IS NULL`, communityID, accountID).Scan(&n); err != nil {
		return ReportRecipient{}, err
	}
	if n == 0 {
		return ReportRecipient{}, ErrNotMember
	}
	inboxID := franking.CommunityModeratorInboxID(communityID, accountID)
	if len(inboxID) > franking.MaxIDSize {
		return ReportRecipient{}, ErrInvalidInput
	}
	var current []byte
	var rev int64
	var updated string
	err = tx.QueryRowContext(ctx, `SELECT public_key, key_rev, updated_at FROM report_inbox_keys WHERE inbox_kind = ? AND inbox_id = ?`, franking.InboxCommunity, inboxID).Scan(&current, &rev, &updated)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		rev = 1
	case err != nil:
		return ReportRecipient{}, err
	case bytes.Equal(current, publicKey):
		return ReportRecipient{InboxID: inboxID, PublicKey: current, KeyRev: rev, UpdatedAt: parseTime(updated)}, nil
	default:
		rev++
	}
	now := nowString()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO report_inbox_keys(inbox_kind, inbox_id, public_key, key_rev, set_by_account_id, updated_at)
		VALUES(?, ?, ?, ?, ?, ?)
		ON CONFLICT(inbox_kind, inbox_id) DO UPDATE SET public_key = excluded.public_key, key_rev = excluded.key_rev, set_by_account_id = excluded.set_by_account_id, updated_at = excluded.updated_at`,
		franking.InboxCommunity, inboxID, publicKey, rev, accountID, now); err != nil {
		return ReportRecipient{}, err
	}
	if err := tx.Commit(); err != nil {
		return ReportRecipient{}, err
	}
	return ReportRecipient{InboxID: inboxID, PublicKey: publicKey, KeyRev: rev, UpdatedAt: parseTime(now)}, nil
}

// CommunityReportKey returns accountID's own moderator key for communityID
// (ErrNotFound when none; ErrForbidden unless still a member).
func (s *Store) CommunityReportKey(ctx context.Context, communityID, accountID string) (ReportRecipient, error) {
	inboxID := franking.CommunityModeratorInboxID(communityID, accountID)
	allowed, err := mayReadReportInbox(ctx, s.db, accountID, franking.InboxCommunity, inboxID)
	if err != nil {
		return ReportRecipient{}, err
	}
	if !allowed {
		return ReportRecipient{}, ErrForbidden
	}
	var r ReportRecipient
	var updated string
	err = s.db.QueryRowContext(ctx, `SELECT inbox_id, public_key, key_rev, updated_at FROM report_inbox_keys WHERE inbox_kind = ? AND inbox_id = ?`, franking.InboxCommunity, inboxID).Scan(&r.InboxID, &r.PublicKey, &r.KeyRev, &updated)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ReportRecipient{}, ErrNotFound
		}
		return ReportRecipient{}, err
	}
	r.UpdatedAt = parseTime(updated)
	return r, nil
}

// InstanceReportKey returns the calling owner's own published report key, so
// an owner's device can show the current key's code after another device
// replaced it. ErrForbidden unless the caller is an active owner; ErrNotFound
// when none was published.
func (s *Store) InstanceReportKey(ctx context.Context, accountID string) (ReportRecipient, error) {
	allowed, err := mayReadReportInbox(ctx, s.db, accountID, franking.InboxInstanceOwner, accountID)
	if err != nil {
		return ReportRecipient{}, err
	}
	if !allowed {
		return ReportRecipient{}, ErrForbidden
	}
	var r ReportRecipient
	var updated string
	err = s.db.QueryRowContext(ctx, `SELECT inbox_id, public_key, key_rev, updated_at FROM report_inbox_keys WHERE inbox_kind = ? AND inbox_id = ?`, franking.InboxInstanceOwner, accountID).Scan(&r.InboxID, &r.PublicKey, &r.KeyRev, &updated)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ReportRecipient{}, ErrNotFound
		}
		return ReportRecipient{}, err
	}
	r.UpdatedAt = parseTime(updated)
	return r, nil
}

type reportQuerier interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
	QueryContext(context.Context, string, ...interface{}) (*sql.Rows, error)
}

// reportInboxForConversation names the inbox a conversation's reports go to:
// a community's channels report to that community's moderators (id is the
// community), a DM or group to the instance owners (no single id: one inbox
// per owner). The server decides, never the reporter.
func reportInboxForConversation(ctx context.Context, q reportQuerier, conversationID string) (kind, id string, err error) {
	var conversationKind string
	var communityID sql.NullString
	if err := q.QueryRowContext(ctx, `SELECT kind, community_id FROM conversations WHERE id = ?`, conversationID).Scan(&conversationKind, &communityID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", "", ErrNotFound
		}
		return "", "", err
	}
	switch {
	case conversationKind == "community_channel" && communityID.Valid && communityID.String != "":
		return franking.InboxCommunity, communityID.String, nil
	case conversationKind == "dm" || conversationKind == "group":
		return franking.InboxInstanceOwner, "", nil
	}
	return "", "", ErrReportInboxUnavailable
}

// ReportInboxForConversation returns where accountID's report about a
// message of conversationID goes, with the keys to seal to. Members only.
func (s *Store) ReportInboxForConversation(ctx context.Context, conversationID, accountID string) (ReportInbox, error) {
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return ReportInbox{}, err
	}
	if !member {
		return ReportInbox{}, ErrNotMember
	}
	return s.reportInbox(ctx, s.db, conversationID)
}

// reportInbox lists the current recipients of a conversation's reports. For
// the instance owners that is every active owner who has published a key (an
// owner who has not cannot open a copy, so none is made for them), in a
// stable order. It is ErrReportInboxUnavailable when there is none.
func (s *Store) reportInbox(ctx context.Context, q reportQuerier, conversationID string) (ReportInbox, error) {
	kind, id, err := reportInboxForConversation(ctx, q, conversationID)
	if err != nil {
		return ReportInbox{}, err
	}
	var rows *sql.Rows
	if kind == franking.InboxInstanceOwner {
		rows, err = q.QueryContext(ctx, `
			SELECT k.inbox_id, k.public_key, k.key_rev, k.updated_at
			FROM report_inbox_keys k JOIN accounts a ON a.id = k.inbox_id
			WHERE k.inbox_kind = ? AND a.role = 'owner' AND a.status = 'active' AND a.deleted_at IS NULL
			ORDER BY k.inbox_id`, kind)
	} else {
		// C6 community inbox: every member of the community who published a
		// moderator key for it and is a member of the reported conversation.
		// The server cannot know who moderates (the verified role record, C4,
		// lives in the apps), so the reporter's app seals only to the listed
		// keys of accounts its record ranks moderator or above, and
		// CreateReport accepts that subset. Every community member is in the
		// shared conversation (and in a legacy community's channels), so the
		// conversation condition only narrows a private channel: a moderator
		// outside it is never offered a copy of what it cannot read (owner
		// decision 2026-11-11, docs/designs/C6-reports-franking.md).
		rows, err = q.QueryContext(ctx, `
			SELECT k.inbox_id, k.public_key, k.key_rev, k.updated_at
			FROM report_inbox_keys k
			JOIN accounts a ON a.id = k.set_by_account_id
			WHERE k.inbox_kind = ?
			  AND k.inbox_id = ? || ':' || a.id
			  AND a.status = 'active' AND a.deleted_at IS NULL
			  AND EXISTS (SELECT 1 FROM memberships m WHERE m.community_id = ? AND m.account_id = a.id)
			  AND EXISTS (SELECT 1 FROM memberships c WHERE c.conversation_id = ? AND c.account_id = a.id)
			ORDER BY k.inbox_id`, kind, id, id, conversationID)
	}
	if err != nil {
		return ReportInbox{}, err
	}
	defer rows.Close()
	inbox := ReportInbox{Kind: kind, Recipients: []ReportRecipient{}}
	for rows.Next() {
		var r ReportRecipient
		var updated string
		if err := rows.Scan(&r.InboxID, &r.PublicKey, &r.KeyRev, &updated); err != nil {
			return ReportInbox{}, err
		}
		r.UpdatedAt = parseTime(updated)
		inbox.Recipients = append(inbox.Recipients, r)
	}
	if err := rows.Err(); err != nil {
		return ReportInbox{}, err
	}
	if len(inbox.Recipients) == 0 {
		return ReportInbox{}, ErrReportInboxUnavailable
	}
	return inbox, nil
}

// ReportCopyInput is one sealed copy of a report: the inbox, and the key
// and revision it was sealed to.
type ReportCopyInput struct {
	InboxID      string
	KeyRev       int64
	RecipientKey []byte
	Sealed       []byte
}

// CreateReportInput is a reporter's filing. The server resolves the inbox
// itself and learns nothing about the message: ReportID is chosen by the
// reporter's app, the same in every copy and in each copy's aad.
type CreateReportInput struct {
	ReporterAccountID string
	ConversationID    string
	ReportID          string
	// Copies must name exactly the conversation's current recipients, each
	// with the key and revision that are still current. A revision alone does
	// not name a key: it restarts at 1 when the owner who published it is
	// deleted and another owner publishes.
	Copies []ReportCopyInput
}

// CreateReport files a sealed report: one stored copy per recipient, in one
// transaction. The reporter must be a current member of the conversation.
// The server never opens a copy and (D95) never sees which message it is
// about, so it cannot check that the message exists, carries a franking
// commitment or is not the reporter's own: the recipient's app checks those
// against the revealed text. Dedupe is by ReportID per reporter.
func (s *Store) CreateReport(ctx context.Context, in CreateReportInput) ([]Report, error) {
	if len(in.ReportID) < minReportIDBytes || len(in.ReportID) > franking.MaxIDSize || len(in.Copies) == 0 || len(in.Copies) > maxReportCopies {
		return nil, ErrInvalidInput
	}
	for _, c := range in.Copies {
		if len(c.Sealed) < MinSealedReportBytes || len(c.Sealed) > MaxSealedReportBytes || string(c.Sealed[:4]) != sealedReportMagic ||
			len(c.RecipientKey) != franking.PublicKeySize || c.KeyRev < 1 || c.InboxID == "" || len(c.InboxID) > franking.MaxIDSize {
			return nil, ErrInvalidInput
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var memberCount int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, in.ConversationID, in.ReporterAccountID).Scan(&memberCount); err != nil {
		return nil, err
	}
	if memberCount == 0 {
		return nil, ErrNotMember
	}
	inbox, err := s.reportInbox(ctx, tx, in.ConversationID)
	if err != nil {
		return nil, err
	}
	// For the instance owners the copies must be exactly the current
	// recipients, each at its current key: a missing owner copy would be a
	// report that owner never gets. For a community they are a non-empty
	// subset: the reporter's app leaves out every listed key whose account its
	// verified role record does not rank moderator or above, which the server
	// cannot check. Each copy still has to be a listed key at its current rev.
	if inbox.Kind == franking.InboxInstanceOwner && len(in.Copies) != len(inbox.Recipients) {
		return nil, ErrReportInboxChanged
	}
	if len(in.Copies) == 0 || len(in.Copies) > len(inbox.Recipients) {
		return nil, ErrReportInboxChanged
	}
	current := make(map[string]ReportRecipient, len(inbox.Recipients))
	for _, r := range inbox.Recipients {
		current[r.InboxID] = r
	}
	seen := make(map[string]bool, len(in.Copies))
	for _, c := range in.Copies {
		r, ok := current[c.InboxID]
		if !ok || seen[c.InboxID] || r.KeyRev != c.KeyRev || !bytes.Equal(r.PublicKey, c.RecipientKey) {
			return nil, ErrReportInboxChanged
		}
		seen[c.InboxID] = true
	}
	now := time.Now().UTC()
	var existing int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports WHERE reporter_account_id = ? AND report_id = ?`, in.ReporterAccountID, in.ReportID).Scan(&existing); err != nil {
		return nil, err
	}
	if existing > 0 {
		return nil, ErrReportDuplicate
	}
	var recent int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(DISTINCT report_id) FROM reports WHERE reporter_account_id = ? AND created_at > ?`, in.ReporterAccountID, formatTime(now.Add(-24*time.Hour))).Scan(&recent); err != nil {
		return nil, err
	}
	if recent >= maxReportsPerReporterPerDay {
		return nil, ErrReportLimit
	}
	reports := make([]Report, 0, len(in.Copies))
	for _, c := range in.Copies {
		var held int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports WHERE inbox_kind = ? AND inbox_id = ?`, inbox.Kind, c.InboxID).Scan(&held); err != nil {
			return nil, err
		}
		if held >= maxReportsPerInbox {
			return nil, ErrReportLimit
		}
		report := Report{
			ReportID:           in.ReportID,
			InboxKind:          inbox.Kind,
			InboxID:            c.InboxID,
			KeyRev:             c.KeyRev,
			RecipientPublicKey: c.RecipientKey,
			ConversationID:     in.ConversationID,
			ReporterAccountID:  in.ReporterAccountID,
			Sealed:             c.Sealed,
			CreatedAt:          now,
		}
		if report.ID, err = domain.NewID("rpt"); err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO reports(id, report_id, inbox_kind, inbox_id, key_rev, recipient_public_key, conversation_id, reporter_account_id, sealed, created_at)
			VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			report.ID, report.ReportID, report.InboxKind, report.InboxID, report.KeyRev, report.RecipientPublicKey, report.ConversationID, report.ReporterAccountID, report.Sealed, formatTime(now)); err != nil {
			return nil, err
		}
		reports = append(reports, report)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return reports, nil
}

// PruneReports deletes up to 500 report copies filed more than
// ReportRetention before now (D95). A copy a recipient dismissed is already
// gone.
func (s *Store) PruneReports(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `DELETE FROM reports WHERE id IN (SELECT id FROM reports WHERE created_at < ? ORDER BY created_at, id LIMIT 500)`, formatTime(now.UTC().Add(-ReportRetention)))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// mayReadReportInbox says whether accountID may list and dismiss the reports
// of an inbox: an instance owner for their own inbox (one inbox per owner,
// D95), an owner, admin or moderator of the community for a community inbox.
// This is routing authorization only. The server holds ciphertext either
// way; opening a report needs the inbox's seed, which the server never sees.
func mayReadReportInbox(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}, accountID, kind, id string) (bool, error) {
	var n int
	switch kind {
	case franking.InboxInstanceOwner:
		if id != accountID {
			return false, nil
		}
		err := q.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND role = 'owner' AND status = 'active' AND deleted_at IS NULL`, accountID).Scan(&n)
		return n > 0, err
	case franking.InboxCommunity:
		// One inbox per moderator per community: only that account, and only
		// while it is still a member. Not a server role: community roles are
		// the apps' verified record (C4); the reporter chose to seal to it.
		err := q.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM memberships m JOIN accounts a ON a.id = m.account_id
			WHERE m.account_id = ? AND m.community_id IS NOT NULL AND m.community_id || ':' || m.account_id = ?
			  AND a.status = 'active' AND a.deleted_at IS NULL`, accountID, id).Scan(&n)
		return n > 0, err
	}
	return false, nil
}

const reportColumns = `id, report_id, inbox_kind, inbox_id, key_rev, recipient_public_key, conversation_id, reporter_account_id, sealed, created_at`

func scanReport(row interface{ Scan(...interface{}) error }) (Report, error) {
	var r Report
	var created string
	if err := row.Scan(&r.ID, &r.ReportID, &r.InboxKind, &r.InboxID, &r.KeyRev, &r.RecipientPublicKey, &r.ConversationID, &r.ReporterAccountID, &r.Sealed, &created); err != nil {
		return Report{}, err
	}
	r.CreatedAt = parseTime(created)
	return r, nil
}

// ListReports returns the reports of an inbox, oldest first, after afterID,
// to an account allowed to read that inbox. Anyone else gets ErrForbidden,
// whether the inbox has reports or not. Copies older than ReportRetention
// are not returned even if the sweeper has not removed them yet.
func (s *Store) ListReports(ctx context.Context, accountID, kind, inboxID, afterID string, limit int) ([]Report, error) {
	allowed, err := mayReadReportInbox(ctx, s.db, accountID, kind, inboxID)
	if err != nil {
		return nil, err
	}
	if !allowed {
		return nil, ErrForbidden
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	query := `SELECT ` + reportColumns + ` FROM reports WHERE inbox_kind = ? AND inbox_id = ? AND created_at >= ?`
	args := []interface{}{kind, inboxID, formatTime(time.Now().UTC().Add(-ReportRetention))}
	if afterID != "" {
		var cursorAt string
		if err := s.db.QueryRowContext(ctx, `SELECT created_at FROM reports WHERE id = ? AND inbox_kind = ? AND inbox_id = ?`, afterID, kind, inboxID).Scan(&cursorAt); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil, ErrNotFound
			}
			return nil, err
		}
		query += ` AND (created_at > ? OR (created_at = ? AND id > ?))`
		args = append(args, cursorAt, cursorAt, afterID)
	}
	query += ` ORDER BY created_at, id LIMIT ?`
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	reports := []Report{}
	for rows.Next() {
		report, err := scanReport(rows)
		if err != nil {
			return nil, err
		}
		reports = append(reports, report)
	}
	return reports, rows.Err()
}

// DeleteReport removes a report copy an account may read. It is how a
// moderator or owner dismisses one; there is no other status in v1. Each
// owner dismisses their own copy; the other owners' copies stay.
func (s *Store) DeleteReport(ctx context.Context, accountID, reportID string) (Report, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Report{}, err
	}
	defer tx.Rollback()
	report, err := scanReport(tx.QueryRowContext(ctx, `SELECT `+reportColumns+` FROM reports WHERE id = ?`, reportID))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Report{}, ErrNotFound
		}
		return Report{}, err
	}
	allowed, err := mayReadReportInbox(ctx, tx, accountID, report.InboxKind, report.InboxID)
	if err != nil {
		return Report{}, err
	}
	if !allowed {
		// Indistinguishable from a missing report.
		return Report{}, ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM reports WHERE id = ?`, reportID); err != nil {
		return Report{}, err
	}
	if err := tx.Commit(); err != nil {
		return Report{}, err
	}
	return report, nil
}

// ReportEnvelopeRecord is what the server recorded when a message was sent
// that a report's recipient needs to verify the report: the sender, the
// conversation, the time and the franking commitment (C6, G1).
type ReportEnvelopeRecord struct {
	EnvelopeID     string `json:"envelope_id"`
	ConversationID string `json:"conversation_id"`
	// The sender fields are empty for a sealed envelope (L2-3), whose
	// sender the server never learned: the verifier attributes it with the
	// franking signature in the report instead.
	SenderAccountID string `json:"sender_account_id,omitempty"`
	SenderDeviceID  string `json:"sender_device_id,omitempty"`
	FrankCommit     []byte `json:"frank_commit,omitempty"`
	Sealed          bool   `json:"sealed,omitempty"`
	// IdempotencyKey is served for a sealed envelope only: the verifier
	// requires it to equal the report's action id, which ties the report
	// to the envelope the message was first stored in, not to a member's
	// copy of its ciphertext and commitment under another key (L2-3 review).
	IdempotencyKey string    `json:"idempotency_key,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
}

// ReportEnvelopeRecord returns the recorded envelope data for a message of
// the conversation a report copy was filed about, to the recipient of that
// copy only (D95: this is the one moment the server learns an envelope id,
// at review time and only from the recipient). An envelope of another
// conversation, a copy of another inbox and a missing report all read as
// ErrNotFound. Nothing here changes a row.
func (s *Store) ReportEnvelopeRecord(ctx context.Context, accountID, reportRowID, envelopeID string) (ReportEnvelopeRecord, error) {
	report, err := scanReport(s.db.QueryRowContext(ctx, `SELECT `+reportColumns+` FROM reports WHERE id = ?`, reportRowID))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ReportEnvelopeRecord{}, ErrNotFound
		}
		return ReportEnvelopeRecord{}, err
	}
	allowed, err := mayReadReportInbox(ctx, s.db, accountID, report.InboxKind, report.InboxID)
	if err != nil {
		return ReportEnvelopeRecord{}, err
	}
	// A copy past its retention that the sweeper has not removed yet is gone
	// as far as listing goes, so it authorizes nothing either.
	if !allowed || report.CreatedAt.Before(time.Now().UTC().Add(-ReportRetention)) {
		return ReportEnvelopeRecord{}, ErrNotFound
	}
	var record ReportEnvelopeRecord
	var created string
	err = s.db.QueryRowContext(ctx, `
		SELECT id, conversation_id, sender_account_id, sender_device_id, frank_commit, created_at
		FROM message_envelopes WHERE id = ? AND conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)`, envelopeID, report.ConversationID, nowString()).
		Scan(&record.EnvelopeID, &record.ConversationID, &record.SenderAccountID, &record.SenderDeviceID, &record.FrankCommit, &created)
	if errors.Is(err, sql.ErrNoRows) {
		// L2-3: a sealed envelope, with no sender.
		record = ReportEnvelopeRecord{Sealed: true}
		err = s.db.QueryRowContext(ctx, `
			SELECT id, conversation_id, frank_commit, idempotency_key, created_at
			FROM sealed_message_envelopes WHERE id = ? AND conversation_id = ? AND (expires_at IS NULL OR expires_at > ?)`, envelopeID, report.ConversationID, nowString()).
			Scan(&record.EnvelopeID, &record.ConversationID, &record.FrankCommit, &record.IdempotencyKey, &created)
	}
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ReportEnvelopeRecord{}, ErrNotFound
		}
		return ReportEnvelopeRecord{}, err
	}
	record.CreatedAt = parseTime(created)
	return record, nil
}
