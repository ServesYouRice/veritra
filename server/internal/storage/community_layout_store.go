package storage

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"reflect"
	"strings"

	"private-messenger/server/internal/domain"
)

// C0 / C1 prerequisite 2: shared-group routing.
//
// A community is in one of two layouts (migration 0049):
//
//   - legacy: one conversation per channel, every member in every channel.
//     Nothing about it changes here.
//   - active: one shared conversation (effective kind community_shared) for
//     all open and announcement channels, and one conversation per private
//     channel. Only the community_layouts, community_conversation_layouts and
//     community_channel_routes rows say so; the physical conversations.kind
//     stays community_channel (see annotateSharedKind for the projection).
//
// Only communities created while Config.CommunityLayout is on get the active
// layout. No legacy community is converted: that needs the signed layout
// control record of docs/designs/C0-preserving-migration.md.
//
// The server sees the channel ID in the clear envelope metadata (owner
// decision D51) and refuses a post whose channel is not an open or
// announcement route of the conversation it is sent to. The same ID is inside
// the encrypted payload (W7), where the receiving app checks it, so the
// server cannot move a post between channels.

const (
	// CommunityLayoutVersion is the only layout version.
	CommunityLayoutVersion = 1

	ChannelAccessOpen         = "open"
	ChannelAccessAnnouncement = "announcement"
	ChannelAccessPrivate      = "private"

	// CommunityShared is the effective kind of a shared conversation.
	CommunityShared = "community_shared"

	// EnvelopeChannelKey and EnvelopeLayoutGenerationKey are the clear
	// envelope metadata keys a post in a shared conversation must carry.
	EnvelopeChannelKey          = "channel_id"
	EnvelopeLayoutGenerationKey = "community_layout_generation"
)

// ErrInvalidChannelRoute refuses an envelope or mutation whose channel
// context is missing, foreign, private, stale or present where it must not be.
var ErrInvalidChannelRoute = errors.New("invalid channel route")

type communityLayout struct {
	active               bool
	generation           int64
	sharedConversationID string
}

// communityLayoutOf reads a community's layout. A community without a row (a
// test fixture inserting directly) is legacy.
func communityLayoutOf(ctx context.Context, q queryRower, communityID string) (communityLayout, error) {
	var state string
	var generation int64
	var shared sql.NullString
	err := q.QueryRowContext(ctx, `SELECT state, generation, shared_conversation_id FROM community_layouts WHERE community_id = ?`, communityID).Scan(&state, &generation, &shared)
	if errors.Is(err, sql.ErrNoRows) {
		return communityLayout{}, nil
	}
	if err != nil {
		return communityLayout{}, err
	}
	return communityLayout{active: state == "active", generation: generation, sharedConversationID: shared.String}, nil
}

// initCommunityLayout writes the layout of a community created in tx. With the
// switch on it also creates the shared conversation, with the creator as its
// owner, in the same transaction.
func (s *Store) initCommunityLayout(ctx context.Context, tx *sql.Tx, communityID, createdBy, createdAt string) error {
	if !s.communityLayout {
		_, err := tx.ExecContext(ctx, `INSERT INTO community_layouts(community_id, version, state, generation) VALUES(?, ?, 'legacy', 0)`, communityID, CommunityLayoutVersion)
		return err
	}
	if err := s.checkOwnConversations(ctx, tx, createdBy, 1); err != nil {
		return err
	}
	conversationID, err := domain.NewID("conv")
	if err != nil {
		return err
	}
	// The shared conversation has no title and no channel: the community
	// name is the community's, and each channel is a route inside it.
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, created_at) VALUES(?, 'community_channel', NULL, ?, NULL, ?, ?)`, conversationID, communityID, createdBy, createdAt); err != nil {
		return err
	}
	if err := insertConversationMember(ctx, tx, conversationID, createdBy, domain.RoleOwner, communityID, createdAt); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO community_layouts(community_id, version, state, generation, shared_conversation_id) VALUES(?, ?, 'active', 1, ?)`, communityID, CommunityLayoutVersion, conversationID); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO community_conversation_layouts(conversation_id, community_id, purpose, generation) VALUES(?, ?, 'shared', 1)`, conversationID, communityID)
	return err
}

// insertConversationMember adds an account to a community conversation and
// records the membership event, as channel creation always has.
func insertConversationMember(ctx context.Context, tx *sql.Tx, conversationID, accountID, role, communityID, createdAt string) error {
	membershipID, err := domain.NewID("mbr")
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(account_id, conversation_id) DO UPDATE SET role = excluded.role`, membershipID, accountID, conversationID, role, createdAt); err != nil {
		return err
	}
	payload, err := json.Marshal(map[string]string{"community_id": communityID, "conversation_id": conversationID, "role": role})
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('membership.updated', ?, ?, ?, ?)`, accountID, conversationID, string(payload), createdAt)
	return err
}

// communityJoinConversationIDs lists the conversations a new community member
// joins: the shared conversation of an active layout (never a private
// channel's), or every channel conversation of a legacy community.
func communityJoinConversationIDs(ctx context.Context, tx *sql.Tx, communityID string) ([]string, error) {
	layout, err := communityLayoutOf(ctx, tx, communityID)
	if err != nil {
		return nil, err
	}
	if layout.active {
		return []string{layout.sharedConversationID}, nil
	}
	rows, err := tx.QueryContext(ctx, `SELECT id FROM conversations WHERE community_id = ? AND kind = 'community_channel'`, communityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	ids := make([]string, 0)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// isSharedConversation reports whether the conversation is the shared
// conversation of an active layout.
func isSharedConversation(ctx context.Context, q queryRower, conversationID string) (bool, error) {
	n, err := countRows(ctx, q, `SELECT COUNT(*) FROM community_conversation_layouts WHERE conversation_id = ? AND purpose = 'shared'`, conversationID)
	return n > 0, err
}

// createRoutedChannel makes a channel in an active layout inside tx. An open
// or announcement channel is a route to the shared conversation and creates no
// conversation. A private channel gets its own conversation with the creator
// as its only member; others join through the existing conversation member
// route, which refuses non-members of the community.
func (s *Store) createRoutedChannel(ctx context.Context, tx *sql.Tx, layout communityLayout, communityID, name, access, createdBy, creatorRole, createdAt string) (domain.Channel, domain.Conversation, error) {
	name = strings.TrimSpace(name)
	channelID, err := domain.NewID("chan")
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	conversationID := layout.sharedConversationID
	if access == ChannelAccessPrivate {
		if conversationID, err = domain.NewID("conv"); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
		if err := s.checkOwnConversations(ctx, tx, createdBy, 1); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
	}
	// channels.kind predates the layouts and cannot hold 'open'. The route's
	// access_mode is the truth for a routed channel; this column only keeps
	// the old announcement label for code that still reads it.
	legacyKind := "private"
	if access == ChannelAccessAnnouncement {
		legacyKind = "announcement"
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO channels(id, community_id, name, kind, created_at) VALUES(?, ?, ?, ?, ?)`, channelID, communityID, name, legacyKind, createdAt); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	if access == ChannelAccessPrivate {
		if _, err := tx.ExecContext(ctx, `INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, created_at) VALUES(?, 'community_channel', ?, ?, ?, ?, ?)`, conversationID, name, communityID, channelID, createdBy, createdAt); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO community_conversation_layouts(conversation_id, community_id, purpose, generation) VALUES(?, ?, 'private', ?)`, conversationID, communityID, layout.generation); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
		if err := insertConversationMember(ctx, tx, conversationID, createdBy, creatorRole, communityID, createdAt); err != nil {
			return domain.Channel{}, domain.Conversation{}, err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO community_channel_routes(channel_id, community_id, conversation_id, access_mode, generation) VALUES(?, ?, ?, ?, ?)`, channelID, communityID, conversationID, access, layout.generation); err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	conversation, err := scanConversation(tx.QueryRowContext(ctx, `SELECT id, kind, title, community_id, channel_id, created_by, retention_seconds, created_at FROM conversations WHERE id = ?`, conversationID))
	if err != nil {
		return domain.Channel{}, domain.Conversation{}, err
	}
	if access != ChannelAccessPrivate {
		conversation.Kind = CommunityShared
	}
	channel := domain.Channel{
		ID: channelID, CommunityID: communityID, Name: name, Kind: access, CreatedAt: parseTime(createdAt),
		ConversationID: &conversationID, LayoutVersion: CommunityLayoutVersion, LayoutGeneration: layout.generation,
	}
	return channel, conversation, nil
}

// checkNewActiveCommunityMember is checkNewCommunityMember for an active
// layout: a new member joins the shared conversation only, so the community
// (which is that conversation's roster) and the account's conversation count
// are the only limits that apply.
func (s *Store) checkNewActiveCommunityMember(ctx context.Context, tx *sql.Tx, communityID, accountID string) error {
	members, err := communityMemberCount(ctx, tx, communityID)
	if err != nil {
		return err
	}
	if err := s.checkMembers(members, 1); err != nil {
		return err
	}
	return s.checkOtherConversations(ctx, tx, accountID, 1)
}

// listChannelsQuery returns the community's channels with their routes. A
// private route is returned only to members of its conversation: the list is
// the server's side of "who can see a private channel".
const listChannelsQuery = `
	SELECT ch.id, ch.community_id, ch.name, ch.kind, ch.created_at,
	       r.conversation_id, r.access_mode, r.generation
	FROM channels ch
	LEFT JOIN community_channel_routes r ON r.channel_id = ch.id
	WHERE ch.community_id = ?1
	  AND (r.channel_id IS NULL OR r.access_mode <> 'private'
	       OR EXISTS (SELECT 1 FROM memberships m WHERE m.conversation_id = r.conversation_id AND m.account_id = ?2))
	ORDER BY ch.created_at, ch.id`

// sharedKindQuerier is the read side of a transaction or the store.
type sharedKindQuerier interface {
	QueryContext(context.Context, string, ...interface{}) (*sql.Rows, error)
}

// annotateSharedKind is the one projection of the effective conversation
// kind: a shared conversation of an active layout reads as community_shared
// everywhere a conversation is returned. It never carries a channel ID, and
// its posting restriction is per channel, so PostingRestricted stays false.
func annotateSharedKind(ctx context.Context, q sharedKindQuerier, conversations []domain.Conversation) error {
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
	rows, err := q.QueryContext(ctx, `SELECT conversation_id FROM community_conversation_layouts WHERE purpose = 'shared' AND conversation_id IN (`+strings.Join(marks, ",")+`)`, args...)
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
			conversations[i].Kind = CommunityShared
			conversations[i].ChannelID = nil
			conversations[i].PostingRestricted = false
		}
	}
	return rows.Err()
}

// envelopeRoute is what admission learned about an envelope's channel.
type envelopeRoute struct {
	shared       bool
	channelID    string
	announcement bool
	generation   int64
}

// metadataFields parses envelope crypto metadata as a JSON object. ok is false
// when it is not one; such metadata carries no route keys. A repeated key keeps
// its last value, as Go and Dart decode it; see metadataRepeatsKey.
func metadataFields(metadata json.RawMessage) (map[string]json.RawMessage, bool) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(metadata, &fields); err != nil || fields == nil {
		return nil, false
	}
	return fields, true
}

// metadataRepeatsKey reports whether a JSON object names the same top-level
// key twice. Go keeps the last value while SQLite json_extract reads the
// first, so in a shared conversation the stored row could name another channel
// than the one admission checked. The metadata is stored byte for byte
// (sameIdempotentMessage compares it, so a retry must match), so such metadata
// is refused rather than rewritten. Invalid JSON and non-objects report false;
// metadataFields already rejects those.
func metadataRepeatsKey(metadata json.RawMessage) bool {
	decoder := json.NewDecoder(bytes.NewReader(metadata))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return false
	}
	seen := map[string]struct{}{}
	for decoder.More() {
		keyToken, err := decoder.Token()
		key, ok := keyToken.(string)
		if err != nil || !ok {
			return false
		}
		if _, dup := seen[key]; dup {
			return true
		}
		seen[key] = struct{}{}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return false
		}
	}
	return false
}

func metadataHasRouteKeys(fields map[string]json.RawMessage) bool {
	_, channel := fields[EnvelopeChannelKey]
	_, generation := fields[EnvelopeLayoutGenerationKey]
	return channel || generation
}

// routeEnvelope checks the channel context of an envelope for conversationID.
//
//   - In a shared conversation the metadata must name an open or announcement
//     channel of that conversation, at the current layout generation.
//   - Anywhere else (legacy channels, private channels, groups, DMs) the
//     channel keys must be absent: a second channel context there could only
//     be an attempt to smuggle a post into a channel.
func routeEnvelope(ctx context.Context, q queryRower, conversationID string, metadata json.RawMessage) (envelopeRoute, error) {
	fields, isObject := metadataFields(metadata)
	var purpose, communityID string
	var generation int64
	err := q.QueryRowContext(ctx, `SELECT purpose, community_id, generation FROM community_conversation_layouts WHERE conversation_id = ?`, conversationID).Scan(&purpose, &communityID, &generation)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && purpose != "shared") {
		if isObject && metadataHasRouteKeys(fields) {
			return envelopeRoute{}, ErrInvalidChannelRoute
		}
		return envelopeRoute{}, nil
	}
	if err != nil {
		return envelopeRoute{}, err
	}
	if !isObject || metadataRepeatsKey(metadata) {
		return envelopeRoute{}, ErrInvalidChannelRoute
	}
	var channelID string
	if err := json.Unmarshal(fields[EnvelopeChannelKey], &channelID); err != nil || channelID == "" {
		return envelopeRoute{}, ErrInvalidChannelRoute
	}
	var claimed int64
	if err := json.Unmarshal(fields[EnvelopeLayoutGenerationKey], &claimed); err != nil || claimed != generation {
		return envelopeRoute{}, ErrInvalidChannelRoute
	}
	var routeConversation, access string
	var routeGeneration int64
	err = q.QueryRowContext(ctx, `SELECT conversation_id, access_mode, generation FROM community_channel_routes WHERE channel_id = ? AND community_id = ?`, channelID, communityID).Scan(&routeConversation, &access, &routeGeneration)
	if errors.Is(err, sql.ErrNoRows) {
		return envelopeRoute{}, ErrInvalidChannelRoute
	}
	if err != nil {
		return envelopeRoute{}, err
	}
	if routeConversation != conversationID || routeGeneration != generation || access == ChannelAccessPrivate {
		return envelopeRoute{}, ErrInvalidChannelRoute
	}
	return envelopeRoute{shared: true, channelID: channelID, announcement: access == ChannelAccessAnnouncement, generation: generation}, nil
}

// sameChannelAsStored makes an edit or delete keep the route of the message
// it replaces. For a message in a shared conversation the stored channel and
// generation are kept (and filled in when the new metadata leaves them out, as
// the default delete marker does); naming another channel is refused. For any
// other message the route keys must stay absent.
func sameChannelAsStored(ctx context.Context, q queryRower, messageID string, metadata json.RawMessage) (json.RawMessage, error) {
	var conversationID, stored string
	err := q.QueryRowContext(ctx, `SELECT conversation_id, crypto_metadata_json FROM message_envelopes WHERE id = ?`, messageID).Scan(&conversationID, &stored)
	if errors.Is(err, sql.ErrNoRows) {
		return metadata, nil // the update itself reports a missing message
	}
	if err != nil {
		return nil, err
	}
	shared, err := isSharedConversation(ctx, q, conversationID)
	if err != nil {
		return nil, err
	}
	fields, isObject := metadataFields(metadata)
	if !shared {
		if isObject && metadataHasRouteKeys(fields) {
			return nil, ErrInvalidChannelRoute
		}
		return metadata, nil
	}
	old, ok := metadataFields(json.RawMessage(stored))
	if !ok || !isObject || metadataRepeatsKey(metadata) || metadataRepeatsKey(json.RawMessage(stored)) {
		return nil, ErrInvalidChannelRoute
	}
	for _, key := range []string{EnvelopeChannelKey, EnvelopeLayoutGenerationKey} {
		oldValue, hasOld := old[key]
		if !hasOld {
			return nil, ErrInvalidChannelRoute
		}
		if newValue, hasNew := fields[key]; hasNew && !sameJSONValue(newValue, oldValue) {
			return nil, ErrInvalidChannelRoute
		}
		fields[key] = oldValue
	}
	merged, err := json.Marshal(fields)
	if err != nil {
		return nil, err
	}
	return merged, nil
}

// sameJSONValue compares two JSON values regardless of spacing.
func sameJSONValue(a, b json.RawMessage) bool {
	var x, y interface{}
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	return reflect.DeepEqual(x, y)
}
