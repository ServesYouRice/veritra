package storage

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
)

// W11 encrypted profiles (docs/designs/W11-profiles.md). The store holds one
// opaque record per account and per group conversation. It never parses the
// ciphertext and never logs it or the key id.

const (
	ProfileKindAccount      = "account"
	ProfileKindConversation = "conversation"
	// ProfileUpdatedEventType carries IDs and versions only, no content.
	ProfileUpdatedEventType = "profile.updated"
	// maxProfileNotices bounds the accounts told by one write. Readers past
	// the bound find the change in their periodic version check.
	maxProfileNotices = 1000
	// MaxProfileVersionQuery bounds each list of a versions request.
	MaxProfileVersionQuery = 200
)

// ErrProfileVersionConflict means the If-Match version is not the stored one.
var ErrProfileVersionConflict = errors.New("profile version conflict")

// EncryptedProfile is one stored record.
type EncryptedProfile struct {
	SubjectKind string
	SubjectID   string
	Version     int64
	KeyID       string
	Ciphertext  []byte
	UpdatedBy   string
	UpdatedAt   time.Time
}

// ProfileVersion is a record's version and key id without its content.
type ProfileVersion struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Version int64  `json:"version"`
	KeyID   string `json:"key_id"`
}

// ProfileNotice is one durable profile.updated event for one account.
type ProfileNotice struct {
	AccountID string
	EventID   int64
	Payload   map[string]interface{}
}

// ProfileWrite is a replace of a record. ExpectedVersion 0 means the first
// write (If-None-Match: *); otherwise it is the version the writer saw.
type ProfileWrite struct {
	Kind            string
	SubjectID       string
	WriterAccountID string
	KeyID           string
	Ciphertext      []byte
	ExpectedVersion int64
}

type profileQuerier interface {
	QueryRowContext(context.Context, string, ...interface{}) *sql.Row
	QueryContext(context.Context, string, ...interface{}) (*sql.Rows, error)
}

// profileReadable is the read rule. An account record is readable by its
// owner and by an account sharing a current conversation membership with the
// owner while neither blocked the other. A group record is readable by the
// group's current members. Everything else reads as missing.
func profileReadable(ctx context.Context, q profileQuerier, readerID, kind, subjectID string) (bool, error) {
	var one int
	var err error
	switch kind {
	case ProfileKindAccount:
		if !domain.ValidID("acct", subjectID) {
			return false, nil
		}
		err = q.QueryRowContext(ctx, `SELECT 1 FROM accounts a WHERE a.id = ?1 AND a.deleted_at IS NULL AND (
			a.id = ?2 OR (
			  EXISTS (SELECT 1 FROM memberships m1 JOIN memberships m2 ON m1.conversation_id = m2.conversation_id
			          WHERE m1.account_id = ?2 AND m2.account_id = ?1)
			  AND NOT EXISTS (SELECT 1 FROM account_blocks b
			          WHERE (b.blocker_account_id = ?2 AND b.blocked_account_id = ?1)
			             OR (b.blocker_account_id = ?1 AND b.blocked_account_id = ?2))))`, subjectID, readerID).Scan(&one)
	case ProfileKindConversation:
		if !domain.ValidID("conv", subjectID) {
			return false, nil
		}
		err = q.QueryRowContext(ctx, `SELECT 1 FROM conversations c JOIN memberships m ON m.conversation_id = c.id
			WHERE c.id = ? AND c.kind = 'group' AND m.account_id = ?`, subjectID, readerID).Scan(&one)
	default:
		return false, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// PutProfile replaces a record in one transaction: authorise the writer,
// check the version, store, and record one profile.updated event for every
// account the read rule admits (the owner's other devices included).
func (s *Store) PutProfile(ctx context.Context, w ProfileWrite) (int64, []ProfileNotice, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, nil, err
	}
	defer tx.Rollback()
	var audience []string
	switch w.Kind {
	case ProfileKindAccount:
		if w.SubjectID != w.WriterAccountID {
			return 0, nil, ErrNotFound
		}
	case ProfileKindConversation:
		// Any current member may write by default (D59); the group must be a
		// real group. A non-member learns nothing: not found.
		ok, err := profileReadable(ctx, tx, w.WriterAccountID, w.Kind, w.SubjectID)
		if err != nil {
			return 0, nil, err
		}
		if !ok {
			return 0, nil, ErrNotFound
		}
	default:
		return 0, nil, ErrInvalidInput
	}
	var current int64
	err = tx.QueryRowContext(ctx, `SELECT version FROM encrypted_profiles WHERE subject_kind = ? AND subject_id = ?`, w.Kind, w.SubjectID).Scan(&current)
	if errors.Is(err, sql.ErrNoRows) {
		current = 0
	} else if err != nil {
		return 0, nil, err
	}
	if current != w.ExpectedVersion {
		return 0, nil, ErrProfileVersionConflict
	}
	next := current + 1
	now := nowString()
	if _, err := tx.ExecContext(ctx, `INSERT INTO encrypted_profiles(subject_kind, subject_id, version, key_id, ciphertext, size_bytes, updated_by_account_id, updated_at)
		VALUES(?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(subject_kind, subject_id) DO UPDATE SET version = excluded.version, key_id = excluded.key_id, ciphertext = excluded.ciphertext, size_bytes = excluded.size_bytes, updated_by_account_id = excluded.updated_by_account_id, updated_at = excluded.updated_at`,
		w.Kind, w.SubjectID, next, w.KeyID, w.Ciphertext, len(w.Ciphertext), w.WriterAccountID, now); err != nil {
		return 0, nil, err
	}
	audience, err = profileAudience(ctx, tx, w.Kind, w.SubjectID)
	if err != nil {
		return 0, nil, err
	}
	notices := make([]ProfileNotice, 0, len(audience))
	for _, id := range audience {
		payload := map[string]interface{}{"subject_kind": w.Kind, "subject_id": w.SubjectID, "version": next, "key_id": w.KeyID}
		account := id
		eventID, err := insertSyncEvent(ctx, tx, ProfileUpdatedEventType, &account, "", payload, now)
		if err != nil {
			return 0, nil, err
		}
		notices = append(notices, ProfileNotice{AccountID: id, EventID: eventID, Payload: payload})
	}
	if err := tx.Commit(); err != nil {
		return 0, nil, err
	}
	return next, notices, nil
}

// profileAudience lists the accounts the read rule admits for the subject,
// the owner first, bounded by maxProfileNotices.
func profileAudience(ctx context.Context, q profileQuerier, kind, subjectID string) ([]string, error) {
	var rows *sql.Rows
	var err error
	if kind == ProfileKindAccount {
		rows, err = q.QueryContext(ctx, `SELECT id FROM (
			SELECT ?1 AS id, 0 AS ord
			UNION
			SELECT DISTINCT m2.account_id, 1 FROM memberships m1 JOIN memberships m2 ON m1.conversation_id = m2.conversation_id
			JOIN accounts a ON a.id = m2.account_id AND a.deleted_at IS NULL
			WHERE m1.account_id = ?1 AND m2.account_id <> ?1
			  AND NOT EXISTS (SELECT 1 FROM account_blocks b
			    WHERE (b.blocker_account_id = ?1 AND b.blocked_account_id = m2.account_id)
			       OR (b.blocker_account_id = m2.account_id AND b.blocked_account_id = ?1))
		) ORDER BY ord, id LIMIT ?2`, subjectID, maxProfileNotices)
	} else {
		rows, err = q.QueryContext(ctx, `SELECT DISTINCT m.account_id FROM memberships m WHERE m.conversation_id = ? ORDER BY m.account_id LIMIT ?`, subjectID, maxProfileNotices)
	}
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

// GetProfile returns the record when the reader may read it. A missing
// record, a stranger and an ex-member are all ErrNotFound.
func (s *Store) GetProfile(ctx context.Context, readerID, kind, subjectID string) (EncryptedProfile, error) {
	ok, err := profileReadable(ctx, s.db, readerID, kind, subjectID)
	if err != nil {
		return EncryptedProfile{}, err
	}
	if !ok {
		return EncryptedProfile{}, ErrNotFound
	}
	var p EncryptedProfile
	var updated string
	err = s.db.QueryRowContext(ctx, `SELECT subject_kind, subject_id, version, key_id, ciphertext, updated_by_account_id, updated_at
		FROM encrypted_profiles WHERE subject_kind = ? AND subject_id = ?`, kind, subjectID).
		Scan(&p.SubjectKind, &p.SubjectID, &p.Version, &p.KeyID, &p.Ciphertext, &p.UpdatedBy, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return EncryptedProfile{}, ErrNotFound
	}
	if err != nil {
		return EncryptedProfile{}, err
	}
	p.UpdatedAt = parseTime(updated)
	return p, nil
}

// ProfileVersions returns version and key id for each listed subject the
// reader may read. Unreadable or missing subjects are left out silently.
func (s *Store) ProfileVersions(ctx context.Context, readerID string, accountIDs, conversationIDs []string) ([]ProfileVersion, error) {
	if len(accountIDs) > MaxProfileVersionQuery || len(conversationIDs) > MaxProfileVersionQuery {
		return nil, ErrInvalidInput
	}
	out := make([]ProfileVersion, 0)
	collect := func(kind string, ids []string) error {
		seen := map[string]bool{}
		for _, id := range ids {
			if seen[id] {
				continue
			}
			seen[id] = true
			ok, err := profileReadable(ctx, s.db, readerID, kind, id)
			if err != nil {
				return err
			}
			if !ok {
				continue
			}
			var v ProfileVersion
			err = s.db.QueryRowContext(ctx, `SELECT version, key_id FROM encrypted_profiles WHERE subject_kind = ? AND subject_id = ?`, kind, id).Scan(&v.Version, &v.KeyID)
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			if err != nil {
				return err
			}
			v.Kind, v.ID = kind, id
			out = append(out, v)
		}
		return nil
	}
	if err := collect(ProfileKindAccount, accountIDs); err != nil {
		return nil, err
	}
	if err := collect(ProfileKindConversation, conversationIDs); err != nil {
		return nil, err
	}
	return out, nil
}

// ClearLegacyConversationTitle removes the plaintext server title of a group
// once its name lives in the encrypted profile. Owner or admin only.
func (s *Store) ClearLegacyConversationTitle(ctx context.Context, conversationID, accountID string) error {
	if !domain.ValidID("conv", conversationID) {
		return ErrNotFound
	}
	ok, err := profileReadable(ctx, s.db, accountID, ProfileKindConversation, conversationID)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotFound
	}
	role, err := s.ConversationMemberRole(ctx, conversationID, accountID)
	if err != nil {
		return err
	}
	if role != domain.RoleOwner && role != domain.RoleAdmin {
		return ErrForbidden
	}
	_, err = s.db.ExecContext(ctx, `UPDATE conversations SET title = NULL WHERE id = ? AND kind = 'group'`, conversationID)
	return err
}
