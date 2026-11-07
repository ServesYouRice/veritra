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
// text. What it records itself, from its own envelope row at filing time, is
// the evidence a verifier needs (sender, commitment, envelope time).

const (
	// MaxSealedReportBytes is the Rust core's largest sealed report
	// (crypto/rust/src/report.rs MAX_SEALED_BYTES).
	MaxSealedReportBytes = 4 + 32 + 256*1024 + 16
	// MinSealedReportBytes is the smallest valid one: magic, enc, one byte, tag.
	MinSealedReportBytes = 4 + 32 + 1 + 16

	sealedReportMagic = "VRP1"

	// maxReportsPerReporterPerDay and maxReportsPerInbox bound what reporting
	// can store (open item 6: rate limits only, no automatic action).
	maxReportsPerReporterPerDay = 20
	maxReportsPerInbox          = 2000
)

var (
	// ErrReportNotReportable: the message carries no franking commitment, or
	// it is the reporter's own.
	ErrReportNotReportable = errors.New("message cannot be reported")
	// ErrReportInboxUnavailable: no report key is published for the inbox.
	ErrReportInboxUnavailable = errors.New("no report key is published for this inbox")
	// ErrReportInboxChanged: the key revision the report was sealed for is
	// no longer the inbox's current one.
	ErrReportInboxChanged = errors.New("report inbox key changed")
	// ErrReportDuplicate: this reporter already reported this message.
	ErrReportDuplicate = errors.New("message already reported by this account")
	// ErrReportLimit: the reporter or the inbox holds too many reports.
	ErrReportLimit = errors.New("too many reports")
)

// ReportInbox is where a conversation's reports go and the key to seal to.
type ReportInbox struct {
	Kind      string    `json:"inbox_kind"`
	ID        string    `json:"inbox_id"`
	PublicKey []byte    `json:"public_key"`
	KeyRev    int64     `json:"key_rev"`
	UpdatedAt time.Time `json:"updated_at"`
}

// Report is a filed report. Sealed is ciphertext; every other field was
// recorded by the server (condition G1), not supplied by the reporter.
type Report struct {
	ID                 string    `json:"id"`
	InboxKind          string    `json:"inbox_kind"`
	InboxID            string    `json:"inbox_id"`
	KeyRev             int64     `json:"key_rev"`
	RecipientPublicKey []byte    `json:"recipient_public_key"`
	ConversationID     string    `json:"conversation_id"`
	EnvelopeID         string    `json:"envelope_id"`
	ReporterAccountID  string    `json:"reporter_account_id"`
	SenderAccountID    string    `json:"sender_account_id"`
	SenderDeviceID     string    `json:"sender_device_id"`
	ActionID           string    `json:"action_id"`
	FrankCommit        []byte    `json:"frank_commit"`
	EnvelopeCreatedAt  time.Time `json:"envelope_created_at"`
	Sealed             []byte    `json:"sealed,omitempty"`
	CreatedAt          time.Time `json:"created_at"`
}

// SetInstanceReportKey publishes the instance owners' report public key.
// Only an active owner may. Publishing the same key again changes nothing;
// a different key raises key_rev, which reports sealed to the old key refuse.
func (s *Store) SetInstanceReportKey(ctx context.Context, accountID string, publicKey []byte) (ReportInbox, error) {
	if len(publicKey) != franking.PublicKeySize {
		return ReportInbox{}, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ReportInbox{}, err
	}
	defer tx.Rollback()
	var role string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM accounts WHERE id = ? AND status = 'active' AND deleted_at IS NULL`, accountID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ReportInbox{}, ErrForbidden
		}
		return ReportInbox{}, err
	}
	if role != domain.RoleOwner {
		return ReportInbox{}, ErrForbidden
	}
	var current []byte
	var rev int64
	var updated string
	err = tx.QueryRowContext(ctx, `SELECT public_key, key_rev, updated_at FROM report_inbox_keys WHERE inbox_kind = ? AND inbox_id = ?`, franking.InboxInstanceOwner, franking.InstanceInboxID).Scan(&current, &rev, &updated)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		rev = 1
	case err != nil:
		return ReportInbox{}, err
	case bytes.Equal(current, publicKey):
		return ReportInbox{Kind: franking.InboxInstanceOwner, ID: franking.InstanceInboxID, PublicKey: current, KeyRev: rev, UpdatedAt: parseTime(updated)}, nil
	default:
		rev++
	}
	now := nowString()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO report_inbox_keys(inbox_kind, inbox_id, public_key, key_rev, set_by_account_id, updated_at)
		VALUES(?, ?, ?, ?, ?, ?)
		ON CONFLICT(inbox_kind, inbox_id) DO UPDATE SET public_key = excluded.public_key, key_rev = excluded.key_rev, set_by_account_id = excluded.set_by_account_id, updated_at = excluded.updated_at`,
		franking.InboxInstanceOwner, franking.InstanceInboxID, publicKey, rev, accountID, now); err != nil {
		return ReportInbox{}, err
	}
	if err := tx.Commit(); err != nil {
		return ReportInbox{}, err
	}
	return ReportInbox{Kind: franking.InboxInstanceOwner, ID: franking.InstanceInboxID, PublicKey: publicKey, KeyRev: rev, UpdatedAt: parseTime(now)}, nil
}

// reportInboxForConversation names the inbox a conversation's reports go to:
// a community's channels report to that community's moderators, a DM or group
// to the instance owners. The server decides, never the reporter.
func reportInboxForConversation(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}, conversationID string) (kind, id string, err error) {
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
		return franking.InboxInstanceOwner, franking.InstanceInboxID, nil
	}
	return "", "", ErrReportInboxUnavailable
}

// ReportInboxForConversation returns where accountID's report about a
// message of conversationID goes, with the key to seal to. Members only.
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

func (s *Store) reportInbox(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}, conversationID string) (ReportInbox, error) {
	kind, id, err := reportInboxForConversation(ctx, q, conversationID)
	if err != nil {
		return ReportInbox{}, err
	}
	inbox := ReportInbox{Kind: kind, ID: id}
	var updated string
	if err := q.QueryRowContext(ctx, `SELECT public_key, key_rev, updated_at FROM report_inbox_keys WHERE inbox_kind = ? AND inbox_id = ?`, kind, id).Scan(&inbox.PublicKey, &inbox.KeyRev, &updated); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ReportInbox{}, ErrReportInboxUnavailable
		}
		return ReportInbox{}, err
	}
	inbox.UpdatedAt = parseTime(updated)
	return inbox, nil
}

// CreateReportInput is a reporter's filing. The server resolves the inbox,
// sender, commitment and envelope time itself.
type CreateReportInput struct {
	ReporterAccountID string
	ConversationID    string
	EnvelopeID        string
	KeyRev            int64
	Sealed            []byte
}

// CreateReport files a sealed report. The reporter must be a current member
// of the envelope's conversation. The server copies the sender, commitment
// and envelope time from its own row (G1) and never opens Sealed.
func (s *Store) CreateReport(ctx context.Context, in CreateReportInput) (Report, error) {
	if len(in.Sealed) < MinSealedReportBytes || len(in.Sealed) > MaxSealedReportBytes || string(in.Sealed[:4]) != sealedReportMagic {
		return Report{}, ErrInvalidInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Report{}, err
	}
	defer tx.Rollback()
	var memberCount int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, in.ConversationID, in.ReporterAccountID).Scan(&memberCount); err != nil {
		return Report{}, err
	}
	if memberCount == 0 {
		return Report{}, ErrNotMember
	}
	now := time.Now().UTC()
	report := Report{
		ConversationID:    in.ConversationID,
		EnvelopeID:        in.EnvelopeID,
		ReporterAccountID: in.ReporterAccountID,
		Sealed:            in.Sealed,
		KeyRev:            in.KeyRev,
		CreatedAt:         now,
	}
	var envelopeCreated string
	var expires sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT sender_account_id, sender_device_id, idempotency_key, frank_commit, created_at, expires_at
		FROM message_envelopes WHERE id = ? AND conversation_id = ?`, in.EnvelopeID, in.ConversationID).
		Scan(&report.SenderAccountID, &report.SenderDeviceID, &report.ActionID, &report.FrankCommit, &envelopeCreated, &expires); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Report{}, ErrNotFound
		}
		return Report{}, err
	}
	if exp := parseOptionalTime(expires); exp != nil && !exp.After(now) {
		return Report{}, ErrMessageExpired
	}
	report.EnvelopeCreatedAt = parseTime(envelopeCreated)
	if len(report.FrankCommit) != franking.CommitSize || report.SenderAccountID == in.ReporterAccountID {
		return Report{}, ErrReportNotReportable
	}
	inbox, err := s.reportInbox(ctx, tx, in.ConversationID)
	if err != nil {
		return Report{}, err
	}
	if inbox.KeyRev != in.KeyRev {
		return Report{}, ErrReportInboxChanged
	}
	report.InboxKind, report.InboxID, report.RecipientPublicKey = inbox.Kind, inbox.ID, inbox.PublicKey
	var existing int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports WHERE reporter_account_id = ? AND envelope_id = ?`, in.ReporterAccountID, in.EnvelopeID).Scan(&existing); err != nil {
		return Report{}, err
	}
	if existing > 0 {
		return Report{}, ErrReportDuplicate
	}
	var recent, held int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports WHERE reporter_account_id = ? AND created_at > ?`, in.ReporterAccountID, formatTime(now.Add(-24*time.Hour))).Scan(&recent); err != nil {
		return Report{}, err
	}
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM reports WHERE inbox_kind = ? AND inbox_id = ?`, inbox.Kind, inbox.ID).Scan(&held); err != nil {
		return Report{}, err
	}
	if recent >= maxReportsPerReporterPerDay || held >= maxReportsPerInbox {
		return Report{}, ErrReportLimit
	}
	if report.ID, err = domain.NewID("rpt"); err != nil {
		return Report{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO reports(id, inbox_kind, inbox_id, key_rev, recipient_public_key, conversation_id, envelope_id, reporter_account_id, sender_account_id, sender_device_id, action_id, frank_commit, envelope_created_at, sealed, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		report.ID, report.InboxKind, report.InboxID, report.KeyRev, report.RecipientPublicKey, report.ConversationID, report.EnvelopeID, report.ReporterAccountID, report.SenderAccountID, report.SenderDeviceID, report.ActionID, report.FrankCommit, formatTime(report.EnvelopeCreatedAt), report.Sealed, formatTime(now)); err != nil {
		return Report{}, err
	}
	if err := tx.Commit(); err != nil {
		return Report{}, err
	}
	return report, nil
}

// mayReadReportInbox says whether accountID may list and dismiss the reports
// of an inbox: an instance owner for the owners' inbox, an owner, admin or
// moderator of the community for a community inbox. This is routing
// authorization only. The server holds ciphertext either way; opening a
// report needs the inbox's seed, which the server never sees.
func mayReadReportInbox(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
}, accountID, kind, id string) (bool, error) {
	var n int
	switch kind {
	case franking.InboxInstanceOwner:
		if id != franking.InstanceInboxID {
			return false, nil
		}
		err := q.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND role = 'owner' AND status = 'active' AND deleted_at IS NULL`, accountID).Scan(&n)
		return n > 0, err
	case franking.InboxCommunity:
		err := q.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM memberships m JOIN accounts a ON a.id = m.account_id
			WHERE m.account_id = ? AND m.community_id = ? AND m.role IN ('owner', 'admin', 'moderator')
			  AND a.status = 'active' AND a.deleted_at IS NULL`, accountID, id).Scan(&n)
		return n > 0, err
	}
	return false, nil
}

const reportColumns = `id, inbox_kind, inbox_id, key_rev, recipient_public_key, conversation_id, envelope_id, reporter_account_id, sender_account_id, sender_device_id, action_id, frank_commit, envelope_created_at, sealed, created_at`

func scanReport(row interface{ Scan(...interface{}) error }) (Report, error) {
	var r Report
	var envelopeCreated, created string
	if err := row.Scan(&r.ID, &r.InboxKind, &r.InboxID, &r.KeyRev, &r.RecipientPublicKey, &r.ConversationID, &r.EnvelopeID, &r.ReporterAccountID, &r.SenderAccountID, &r.SenderDeviceID, &r.ActionID, &r.FrankCommit, &envelopeCreated, &r.Sealed, &created); err != nil {
		return Report{}, err
	}
	r.EnvelopeCreatedAt = parseTime(envelopeCreated)
	r.CreatedAt = parseTime(created)
	return r, nil
}

// ListReports returns the reports of an inbox, oldest first, after afterID,
// to an account allowed to read that inbox. Anyone else gets ErrForbidden,
// whether the inbox has reports or not.
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
	query := `SELECT ` + reportColumns + ` FROM reports WHERE inbox_kind = ? AND inbox_id = ?`
	args := []interface{}{kind, inboxID}
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

// DeleteReport removes a report an account may read. It is how a moderator
// or owner dismisses one; there is no other status in v1.
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
