package storage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

// C7 targeted history_sync delivery (owner answer Q3, 2026-11-12;
// docs/designs/C7-channel-history.md, "Build status (2026-11-12): step 4
// continued"): a history_sync goes only to the devices its commit added,
// and to its sender (the echo). Existing members never receive its slots.
//
// Every group-level envelope in a community conversation while C7 is on
// names, in clear metadata, which of the two group-level types it is and
// for which epoch:
//
//   - c7_sync_for_epoch: a history_sync for the membership commit that
//     produced that epoch. Its recipients are the group's devices whose
//     joined_epoch is that epoch, which the server already wrote when it
//     stored the commit. A second history_sync for the same epoch is
//     refused (409 history_sync_delivered) until a request reopens it.
//   - c7_sync_request_for_epoch: a newcomer's history_sync_request. The
//     epoch must be the sending device's own joined_epoch. It goes to every
//     member, as before, and reopens delivery for that epoch.
//
// The server learns nothing new: it wrote each device's joined_epoch
// itself, and the size rule already tells a history_sync from a request.
// Storage and the history route are unchanged, so a later newcomer's
// backward walk can still read every earlier history_sync.

const (
	// EnvelopeC7SyncKey names the epoch a history_sync answers.
	EnvelopeC7SyncKey = "c7_sync_for_epoch"
	// EnvelopeC7SyncRequestKey names the epoch a history_sync_request asks
	// for: always its sender's own join epoch.
	EnvelopeC7SyncRequestKey = "c7_sync_request_for_epoch"
)

// ErrInvalidHistorySyncTarget answers a group-level envelope whose C7 sync
// key is missing, malformed, on the wrong body size, or not the sender's own
// join epoch, and any C7 sync key outside a group-level C7 envelope.
var ErrInvalidHistorySyncTarget = errors.New("invalid history sync target")

// ErrHistorySyncDelivered answers a history_sync for an epoch that already
// has one and no request since.
var ErrHistorySyncDelivered = errors.New("history sync delivered")

type c7SyncKind int

const (
	c7SyncNone c7SyncKind = iota
	c7SyncBody
	c7SyncRequest
)

// c7SyncTag is what an envelope's metadata says about the C7 group-level
// type it carries.
type c7SyncTag struct {
	kind  c7SyncKind
	epoch int64
}

// c7SyncTagOf reads the two keys. Both at once, a repeated key, or a value
// that is not a non-negative integer literal is invalid.
func c7SyncTagOf(metadata json.RawMessage) (c7SyncTag, error) {
	fields, ok := metadataFields(metadata)
	if !ok {
		return c7SyncTag{}, nil
	}
	sync, hasSync := fields[EnvelopeC7SyncKey]
	request, hasRequest := fields[EnvelopeC7SyncRequestKey]
	if !hasSync && !hasRequest {
		return c7SyncTag{}, nil
	}
	if hasSync && hasRequest || metadataRepeatsKey(metadata) {
		return c7SyncTag{}, ErrInvalidHistorySyncTarget
	}
	raw, kind := sync, c7SyncBody
	if hasRequest {
		raw, kind = request, c7SyncRequest
	}
	text := strings.TrimSpace(string(raw))
	value, err := strconv.ParseInt(text, 10, 64)
	if err != nil || value < 0 || text != strconv.FormatInt(value, 10) {
		return c7SyncTag{}, ErrInvalidHistorySyncTarget
	}
	return c7SyncTag{kind: kind, epoch: value}, nil
}

// C7TargetedSync reports whether stored metadata marks a targeted
// history_sync, whose realtime frame must carry neither ciphertext nor body.
func C7TargetedSync(metadata json.RawMessage) bool {
	tag, err := c7SyncTagOf(metadata)
	return err == nil && tag.kind == c7SyncBody
}

// checkC7SyncTag applies the targeting rule to one new envelope inside its
// send transaction. groupLevel is a C0-layout conversation's envelope with
// no channel keys. It returns the tag of an accepted group-level envelope.
func (s *Store) checkC7SyncTag(ctx context.Context, tx *sql.Tx, conversationID, senderDeviceID string, metadata json.RawMessage, sealed []byte, groupLevel bool) (c7SyncTag, error) {
	tag, err := c7SyncTagOf(metadata)
	if err != nil {
		return c7SyncTag{}, err
	}
	if !s.c7History || !groupLevel {
		if tag.kind != c7SyncNone {
			return c7SyncTag{}, ErrInvalidHistorySyncTarget
		}
		return tag, nil
	}
	// The only group-level types are history_sync and its request, and each
	// says which it is.
	switch tag.kind {
	case c7SyncBody:
		if !c7SyncBodySize(len(sealed)) {
			return c7SyncTag{}, ErrInvalidHistorySyncTarget
		}
	case c7SyncRequest:
		if !c7ChannelBodySize(len(sealed)) {
			return c7SyncTag{}, ErrInvalidHistorySyncTarget
		}
	default:
		return c7SyncTag{}, ErrInvalidHistorySyncTarget
	}
	// Targeting needs the group's roster: without one the join filter
	// serves everyone.
	var joined sql.NullInt64
	err = tx.QueryRowContext(ctx, `SELECT jd.joined_epoch FROM conversation_mls_groups g
		JOIN conversation_mls_devices jd ON jd.conversation_id = g.conversation_id
		WHERE g.conversation_id = ? AND jd.device_id = ? AND jd.removed_after_event_id IS NULL`,
		conversationID, senderDeviceID).Scan(&joined)
	if errors.Is(err, sql.ErrNoRows) {
		return c7SyncTag{}, ErrInvalidHistorySyncTarget
	}
	if err != nil {
		return c7SyncTag{}, err
	}
	if tag.kind == c7SyncRequest {
		if !joined.Valid || joined.Int64 != tag.epoch {
			return c7SyncTag{}, ErrInvalidHistorySyncTarget
		}
		return tag, nil
	}
	delivered, err := historySyncDelivered(ctx, tx, conversationID, tag.epoch)
	if err != nil {
		return c7SyncTag{}, err
	}
	if delivered {
		return c7SyncTag{}, ErrHistorySyncDelivered
	}
	return tag, nil
}

// historySyncDelivered reports whether conversationID holds a live
// history_sync for forEpoch with no request for it since. It reads only the
// group-level stream (envelope_bodies_fetch, channel_id NULL), which holds
// history_syncs and requests alone.
func historySyncDelivered(ctx context.Context, q queryRower, conversationID string, forEpoch int64) (bool, error) {
	var lastSync, lastRequest int64
	err := q.QueryRowContext(ctx, `SELECT
		COALESCE(MAX(CASE WHEN json_extract(me.crypto_metadata_json, '$.`+EnvelopeC7SyncKey+`') = ?2 THEN b.sync_event_id END), 0),
		COALESCE(MAX(CASE WHEN json_extract(me.crypto_metadata_json, '$.`+EnvelopeC7SyncRequestKey+`') = ?2 THEN b.sync_event_id END), 0)
		FROM envelope_bodies b
		JOIN message_envelopes me ON me.id = b.message_id
		WHERE b.conversation_id = ?1 AND b.channel_id IS NULL AND b.sync_event_id IS NOT NULL
		  AND me.deleted_at IS NULL AND (me.expires_at IS NULL OR me.expires_at > ?3)`,
		conversationID, forEpoch, nowString()).Scan(&lastSync, &lastRequest)
	if err != nil {
		return false, err
	}
	return lastSync > 0 && lastRequest < lastSync, nil
}

// HistorySyncDelivered is the members' check before a fallback
// history_sync: whether one for forEpoch is already delivered (and not
// reopened by a request). Current member devices of a community
// conversation only; not found while C7 is off.
func (s *Store) HistorySyncDelivered(ctx context.Context, accountID, deviceID, conversationID string, forEpoch int64) (bool, error) {
	if !s.c7History {
		return false, ErrNotFound
	}
	if forEpoch < 0 {
		return false, ErrInvalidInput
	}
	member, err := s.IsConversationMember(ctx, conversationID, accountID)
	if err != nil {
		return false, err
	}
	if !member {
		return false, ErrNotMember
	}
	community, err := conversationIsCommunity(ctx, s.db, conversationID)
	if err != nil {
		return false, err
	}
	if !community {
		return false, ErrNotFound
	}
	inGroup, err := currentGroupDevice(ctx, s.db, conversationID, deviceID)
	if err != nil {
		return false, err
	}
	if !inGroup {
		return false, ErrForbidden
	}
	return historySyncDelivered(ctx, s.db, conversationID, forEpoch)
}

// c7SyncTargetFilter is the join-filter clause (inside the EXISTS over the
// reading device's roster row jd) that limits a targeted history_sync to
// the devices that joined at its epoch and to its sender.
const c7SyncTargetFilter = `(se.event_type NOT LIKE 'message.envelope.%'
			OR json_type(se.payload_json, '$.envelope.crypto_metadata.` + EnvelopeC7SyncKey + `') IS NOT 'integer'
			OR json_extract(se.payload_json, '$.envelope.crypto_metadata.` + EnvelopeC7SyncKey + `') = jd.joined_epoch
			OR json_extract(se.payload_json, '$.envelope.sender_device_id') = jd.device_id)`

// c7SyncRecipientAccounts are the accounts a targeted history_sync is sent
// to live: those with a device that joined at forEpoch, and the sender's
// (its echo), less any that blocked the sender.
func c7SyncRecipientAccounts(ctx context.Context, tx *sql.Tx, conversationID, senderAccountID string, forEpoch int64) ([]string, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT DISTINCT m.account_id FROM memberships m
		WHERE m.conversation_id = ?1
		  AND (m.account_id = ?2 OR EXISTS (SELECT 1 FROM conversation_mls_devices jd
		    WHERE jd.conversation_id = m.conversation_id AND jd.account_id = m.account_id
		      AND jd.joined_epoch = ?3 AND jd.removed_after_event_id IS NULL))
		  AND NOT EXISTS (SELECT 1 FROM account_blocks b WHERE b.blocker_account_id = m.account_id AND b.blocked_account_id = ?2)
		ORDER BY m.account_id`, conversationID, senderAccountID, forEpoch)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var accounts []string
	for rows.Next() {
		var account string
		if err := rows.Scan(&account); err != nil {
			return nil, err
		}
		accounts = append(accounts, account)
	}
	return accounts, rows.Err()
}
