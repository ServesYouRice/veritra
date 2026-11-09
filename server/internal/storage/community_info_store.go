package storage

import (
	"context"
	"database/sql"
	"errors"

	"private-messenger/server/internal/domain"
)

// C3 encrypted community info (docs/designs/C3-private-channels-and-info.md).
// Names, topics and icons of communities, categories and channels are W11
// records with three more subject kinds, kept in the same table by the same
// code. The server sees IDs only.

const (
	ProfileKindCommunity = "community"
	ProfileKindCategory  = "category"
	ProfileKindChannel   = "channel"
	// InfoUpdatedEventType is profile.updated for the three C3 kinds: IDs,
	// version and key id, never content. Older apps skip it (P5).
	InfoUpdatedEventType = "info.updated"
	// CategoryIDPrefix is the prefix of an app-chosen category ID.
	CategoryIDPrefix = "cat"
	// maxCommunityCategories bounds the category IDs one community may bind.
	// The design's limit (50 live categories) is the apps' to keep: the server
	// cannot tell a removed (tombstoned) category from a live one, so this is
	// only an abuse bound.
	maxCommunityCategories = 200
)

// ErrCategoryLimit means the community has bound its maximum of category IDs.
var ErrCategoryLimit = errors.New("category limit reached")

func isInfoKind(kind string) bool {
	return kind == ProfileKindCommunity || kind == ProfileKindCategory || kind == ProfileKindChannel
}

// profileEventType is the sync event a write of this kind records.
func profileEventType(kind string) string {
	if isInfoKind(kind) {
		return InfoUpdatedEventType
	}
	return ProfileUpdatedEventType
}

// channelCarrierQuery yields the conversation that carries a channel: its
// route in a shared-group layout (the shared conversation for an open or
// announcement channel, its own one for a private channel), otherwise the
// legacy one-conversation-per-channel row. The channel ID is ?1.
const channelCarrierQuery = `SELECT COALESCE(
	(SELECT r.conversation_id FROM community_channel_routes r WHERE r.channel_id = ch.id),
	(SELECT c.id FROM conversations c WHERE c.channel_id = ch.id AND c.kind = 'community_channel' ORDER BY c.created_at, c.id LIMIT 1))
	FROM channels ch WHERE ch.id = ?1`

// infoReadable is the read rule of the three C3 kinds. A community or
// category record is readable by the community's members. A channel record is
// readable by the members of the conversation that carries the channel: every
// community member for an open or announcement channel, only that channel's
// members for a private one. Everything else reads as missing.
func infoReadable(ctx context.Context, q profileQuerier, readerID, kind, subjectID string) (bool, error) {
	var one int
	var err error
	switch kind {
	case ProfileKindCommunity:
		if !domain.ValidID("comm", subjectID) {
			return false, nil
		}
		err = q.QueryRowContext(ctx, `SELECT 1 FROM memberships WHERE community_id = ? AND account_id = ?`, subjectID, readerID).Scan(&one)
	case ProfileKindCategory:
		if !domain.ValidID(CategoryIDPrefix, subjectID) {
			return false, nil
		}
		err = q.QueryRowContext(ctx, `SELECT 1 FROM community_categories k JOIN memberships m ON m.community_id = k.community_id
			WHERE k.id = ? AND m.account_id = ?`, subjectID, readerID).Scan(&one)
	case ProfileKindChannel:
		if !domain.ValidID("chan", subjectID) {
			return false, nil
		}
		err = q.QueryRowContext(ctx, `SELECT 1 FROM memberships m WHERE m.account_id = ?2
			AND m.conversation_id = (`+channelCarrierQuery+`)`, subjectID, readerID).Scan(&one)
	default:
		return false, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// authorizeInfoWrite decides a C3 write inside tx. A reader who may not
// write is ErrForbidden; anyone else who may not write is ErrNotFound (no
// existence oracle).
//
//   - community and category: the community's owner or admins (built-in
//     roles; moderators may not). The first write of a category binds its ID
//     to communityID; a category bound to another community is not found.
//   - channel: any reader (D80: any member may edit channel names and topics
//     unless admins restrict it). The server cannot see that restriction; the
//     apps enforce it from the C4 role state, and ignore records whose
//     announcement does not come from an allowed editor.
func authorizeInfoWrite(ctx context.Context, tx *sql.Tx, w ProfileWrite) error {
	switch w.Kind {
	case ProfileKindChannel:
		ok, err := infoReadable(ctx, tx, w.WriterAccountID, w.Kind, w.SubjectID)
		if err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		return nil
	case ProfileKindCommunity, ProfileKindCategory:
	default:
		return ErrInvalidInput
	}
	communityID := w.SubjectID
	if w.Kind == ProfileKindCategory {
		if !domain.ValidID(CategoryIDPrefix, w.SubjectID) || !domain.ValidID("comm", w.CommunityID) {
			return ErrNotFound
		}
		communityID = w.CommunityID
	} else if !domain.ValidID("comm", communityID) {
		return ErrNotFound
	}
	var role string
	err := tx.QueryRowContext(ctx, `SELECT role FROM memberships WHERE community_id = ? AND account_id = ?`, communityID, w.WriterAccountID).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if w.Kind == ProfileKindCategory {
		var bound string
		err := tx.QueryRowContext(ctx, `SELECT community_id FROM community_categories WHERE id = ?`, w.SubjectID).Scan(&bound)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			// A new category: only its first write binds it, and only an
			// owner or admin may create one. A non-zero If-Match on an unbound
			// ID is not found, as for any missing record.
			if w.ExpectedVersion != 0 {
				return ErrNotFound
			}
			if role != domain.RoleOwner && role != domain.RoleAdmin {
				return ErrForbidden
			}
			var count int
			if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM community_categories WHERE community_id = ?`, communityID).Scan(&count); err != nil {
				return err
			}
			if count >= maxCommunityCategories {
				return ErrCategoryLimit
			}
			_, err = tx.ExecContext(ctx, `INSERT INTO community_categories(id, community_id, created_by_account_id, created_at) VALUES(?, ?, ?, ?)`,
				w.SubjectID, communityID, w.WriterAccountID, nowString())
			return err
		case err != nil:
			return err
		case bound != communityID:
			return ErrNotFound
		}
	}
	if role != domain.RoleOwner && role != domain.RoleAdmin {
		return ErrForbidden
	}
	return nil
}

// infoAudience lists the accounts the read rule admits, bounded.
func infoAudience(ctx context.Context, q profileQuerier, kind, subjectID string) (*sql.Rows, error) {
	switch kind {
	case ProfileKindCommunity:
		return q.QueryContext(ctx, `SELECT account_id FROM memberships WHERE community_id = ? ORDER BY account_id LIMIT ?`, subjectID, maxProfileNotices)
	case ProfileKindCategory:
		return q.QueryContext(ctx, `SELECT m.account_id FROM community_categories k JOIN memberships m ON m.community_id = k.community_id
			WHERE k.id = ? ORDER BY m.account_id LIMIT ?`, subjectID, maxProfileNotices)
	case ProfileKindChannel:
		return q.QueryContext(ctx, `SELECT DISTINCT m.account_id FROM memberships m
			WHERE m.conversation_id = (`+channelCarrierQuery+`) ORDER BY m.account_id LIMIT ?2`, subjectID, maxProfileNotices)
	}
	return nil, ErrInvalidInput
}

// GetCategoryInfo returns a category record through its community's route:
// a category bound to another community reads as missing.
func (s *Store) GetCategoryInfo(ctx context.Context, readerID, communityID, categoryID string) (EncryptedProfile, error) {
	var bound string
	err := s.db.QueryRowContext(ctx, `SELECT community_id FROM community_categories WHERE id = ?`, categoryID).Scan(&bound)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && bound != communityID) {
		return EncryptedProfile{}, ErrNotFound
	}
	if err != nil {
		return EncryptedProfile{}, err
	}
	return s.GetProfile(ctx, readerID, ProfileKindCategory, categoryID)
}
