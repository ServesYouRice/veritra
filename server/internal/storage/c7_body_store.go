package storage

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"

	"private-messenger/server/internal/domain"
)

// C7 step 3 (docs/designs/C7-channel-history.md, "Server: wire, storage,
// routes"): every envelope in a community conversation carries a sealed body
// beside its MLS reference. The server stores the body opaquely in
// envelope_bodies (migration 0083) for exactly as long as its envelope, and
// serves it with the envelope. It never learns the channel's history setting:
// every mode sends the same sizes and requests.
//
// The whole step is behind PRIVATE_MESSENGER_C7_HISTORY (off by default)
// until the app sends bodies (build step 4). Off: a body is refused and the
// legacy routes behave as before. On: a body is required in community
// conversations, refused elsewhere, and the legacy edit, delete and paging
// routes answer 409 there.

const (
	// c7BodyFraming is the fixed part of every sealed body: the 124 bytes of
	// key commitment, nonce, tag and framing around the padded VAP1.
	c7BodyFraming = 124
	// c7BodyBlock is the padding block of a channel body.
	c7BodyBlock = 256
	// c7MaxChannelBody is the 65,536-byte VAP1 cap plus framing.
	c7MaxChannelBody = c7BodyFraming + 65536
	// c7SyncSlotBytes is the per-channel slot of a history_sync body.
	c7SyncSlotBytes = 700
	// c7MaxSyncChannels bounds N in a history_sync body (the C3 channel cap).
	c7MaxSyncChannels = 500
)

// ErrHistoryRouteOnly answers a legacy edit, delete or page in a community
// conversation once C7 is on: there history lives in sealed bodies.
var ErrHistoryRouteOnly = errors.New("history route only")

// ErrInvalidSealedBody answers a body that is missing where required, present
// where refused, or of a size outside the C7 rule.
var ErrInvalidSealedBody = errors.New("invalid sealed body")

// c7ChannelBodySize reports whether n is a channel body size: 124 + 256*k for
// k >= 1, at most 65,660 bytes.
func c7ChannelBodySize(n int) bool {
	return n > c7BodyFraming && n <= c7MaxChannelBody && (n-c7BodyFraming)%c7BodyBlock == 0
}

// c7SyncBodySize reports whether n is exactly P(N) + 124 + 700*N for some
// 1 <= N <= 500, with P(N) = 256 * ceil((512 + 128*N) / 256).
func c7SyncBodySize(n int) bool {
	for channels := 1; channels <= c7MaxSyncChannels; channels++ {
		padded := 256 * ((512 + 128*channels + 255) / 256)
		size := padded + c7BodyFraming + c7SyncSlotBytes*channels
		if size == n {
			return true
		}
		if size > n {
			return false
		}
	}
	return false
}

// C7BodySizeValid is the size rule for a sealed body: a channel post's body,
// or (group-level only, no channel_id) also a history_sync body.
func C7BodySizeValid(n int, groupLevel bool) bool {
	return c7ChannelBodySize(n) || (groupLevel && c7SyncBodySize(n))
}

// conversationIsCommunity reports whether a conversation belongs to a
// community (its shared group or a channel's own group).
func conversationIsCommunity(ctx context.Context, q queryRower, conversationID string) (bool, error) {
	var community bool
	err := q.QueryRowContext(ctx, `SELECT c.kind = 'community_channel' OR c.community_id IS NOT NULL
		OR EXISTS (SELECT 1 FROM community_conversation_layouts l WHERE l.conversation_id = c.id)
		FROM conversations c WHERE c.id = ?`, conversationID).Scan(&community)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	return community, err
}

// checkSealedBody applies the body rule for one new envelope.
func (s *Store) checkSealedBody(ctx context.Context, q queryRower, envelope domain.MessageEnvelope, channelID string) error {
	if !s.c7History {
		if len(envelope.SealedBody) != 0 {
			return ErrInvalidSealedBody
		}
		return nil
	}
	community, err := conversationIsCommunity(ctx, q, envelope.ConversationID)
	if err != nil {
		return err
	}
	if !community {
		if len(envelope.SealedBody) != 0 {
			return ErrInvalidSealedBody
		}
		return nil
	}
	if !C7BodySizeValid(len(envelope.SealedBody), strings.TrimSpace(channelID) == "") {
		return ErrInvalidSealedBody
	}
	return nil
}

// insertSealedBody stores the body in the send transaction, with the
// envelope's lifetime, the sync event that carries it (0: none) and the MLS
// epoch the envelope names.
func insertSealedBody(ctx context.Context, tx *sql.Tx, envelope domain.MessageEnvelope, channelID string, eventID int64) error {
	if len(envelope.SealedBody) == 0 {
		return nil
	}
	var expires interface{}
	if envelope.ExpiresAt != nil {
		expires = formatTime(*envelope.ExpiresAt)
	}
	var channel interface{}
	if strings.TrimSpace(channelID) != "" {
		channel = channelID
	}
	var event interface{}
	if eventID > 0 {
		event = eventID
	}
	var epoch interface{}
	if value := metadataEpoch(envelope.CryptoMetadata); value != nil {
		epoch = *value
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO envelope_bodies(message_id, conversation_id, channel_id, created_at, expires_at, body, sync_event_id, mls_epoch) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		envelope.ID, envelope.ConversationID, channel, formatTime(envelope.CreatedAt), expires, envelope.SealedBody, event, epoch)
	return err
}

// sealedBodyOf is a stored envelope's body, or nil.
func sealedBodyOf(ctx context.Context, q queryRower, messageID string) ([]byte, error) {
	var body []byte
	err := q.QueryRowContext(ctx, `SELECT body FROM envelope_bodies WHERE message_id = ?`, messageID).Scan(&body)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return body, err
}

// withSealedBody fills in a stored envelope's body (the replay comparison).
func withSealedBody(ctx context.Context, q queryRower, msg domain.MessageEnvelope, err error) (domain.MessageEnvelope, error) {
	if err != nil {
		return msg, err
	}
	body, err := sealedBodyOf(ctx, q, msg.ID)
	if err != nil {
		return domain.MessageEnvelope{}, err
	}
	msg.SealedBody = body
	return msg, nil
}

// refuseLegacyCommunityRoute answers ErrHistoryRouteOnly for a legacy edit,
// delete or page in a community conversation while C7 is on.
func (s *Store) refuseLegacyCommunityRoute(ctx context.Context, q queryRower, conversationID string) error {
	if !s.c7History {
		return nil
	}
	community, err := conversationIsCommunity(ctx, q, conversationID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil
		}
		return err
	}
	if community {
		return ErrHistoryRouteOnly
	}
	return nil
}

// refuseLegacyCommunityMessage is refuseLegacyCommunityRoute for the
// conversation of a stored envelope. A missing envelope passes; the caller
// reports it.
func (s *Store) refuseLegacyCommunityMessage(ctx context.Context, q queryRower, messageID string) error {
	if !s.c7History {
		return nil
	}
	var conversationID string
	err := q.QueryRowContext(ctx, `SELECT conversation_id FROM message_envelopes WHERE id = ?`, messageID).Scan(&conversationID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	return s.refuseLegacyCommunityRoute(ctx, q, conversationID)
}

// sameSealedBody is the replay comparison of two bodies.
func sameSealedBody(existing, requested []byte) bool {
	return bytes.Equal(existing, requested)
}

// attachSyncBodies serves each created envelope's sealed body with its sync
// event, read from envelope_bodies: the stored event never holds it, so a
// pruned envelope's body is gone with it. Events without a body (every
// event outside community conversations) are left byte for byte as stored,
// and with C7 off nothing is read: the default sync path is unchanged.
func (s *Store) attachSyncBodies(ctx context.Context, q queryRower, events []domain.SyncEvent) error {
	if !s.c7History {
		return nil
	}
	for i := range events {
		if events[i].Type != "message.envelope.created" || events[i].ConversationID == "" || len(events[i].Payload) == 0 {
			continue
		}
		var payload map[string]json.RawMessage
		if err := json.Unmarshal(events[i].Payload, &payload); err != nil {
			continue
		}
		var messageID string
		if err := json.Unmarshal(payload["message_id"], &messageID); err != nil || messageID == "" {
			continue
		}
		body, err := sealedBodyOf(ctx, q, messageID)
		if err != nil {
			return err
		}
		if body == nil {
			continue
		}
		var envelope map[string]json.RawMessage
		if err := json.Unmarshal(payload["envelope"], &envelope); err != nil || envelope == nil {
			continue
		}
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		envelope["sealed_body"] = encoded
		if payload["envelope"], err = json.Marshal(envelope); err != nil {
			return err
		}
		if events[i].Payload, err = json.Marshal(payload); err != nil {
			return err
		}
	}
	return nil
}
