package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

// C7 step 3 storage (docs/designs/C7-channel-history.md, "Server: wire,
// storage, routes"): the sealed-body rule, the replay comparison, bodies on
// sync only, the history fetch against the I51 join filter, former members'
// keys, history-hide and the group-level posting exemption.

// c7Body is a sealed body of n bytes, filled with fill.
func c7Body(n int, fill byte) []byte { return bytes.Repeat([]byte{fill}, n) }

const (
	c7PostBytes = c7BodyFraming + c7BodyBlock // the smallest channel body
	// c7PrivateSyncBytes is a one-channel history_sync: P(1) + 124 + 700.
	c7PrivateSyncBytes = 768 + c7BodyFraming + c7SyncSlotBytes
)

func newC7Fixture(t *testing.T, ctx context.Context) layoutFixture {
	t.Helper()
	f := newLayoutFixture(t, ctx)
	f.store.c7History = true
	return f
}

func (f layoutFixture) epochMetadata(channelID string, generation, epoch int64) json.RawMessage {
	fields := map[string]interface{}{"protocol_version": 1, "mls_epoch": epoch}
	if channelID != "" {
		fields[EnvelopeChannelKey] = channelID
	}
	if generation != 0 {
		fields[EnvelopeLayoutGenerationKey] = generation
	}
	raw, _ := json.Marshal(fields)
	return raw
}

// syncMetadata is a group-level envelope's metadata at epoch, naming the
// history_sync (key EnvelopeC7SyncKey) or request (EnvelopeC7SyncRequestKey)
// it carries for forEpoch.
func (f layoutFixture) syncMetadata(key string, epoch, forEpoch int64) json.RawMessage {
	raw, _ := json.Marshal(map[string]interface{}{"protocol_version": 1, "mls_epoch": epoch, key: forEpoch})
	return raw
}

// postBody sends a two-part envelope and returns it with its sync event.
func (f layoutFixture) postBody(ctx context.Context, conversationID string, who AccountDevice, key string, metadata json.RawMessage, body []byte) (domain.MessageEnvelope, int64, error) {
	envelope, _, event, err := f.store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{
		ConversationID: conversationID, SenderAccountID: who.Account.ID, SenderDeviceID: who.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("reference"), CryptoProtocol: "mls10-openmls-v1",
		CryptoMetadata: metadata, SealedBody: body,
	})
	return envelope, event, err
}

// inGroup records a device in a conversation's MLS roster with its join
// cursor and epoch (what the MLS commit routes write).
func (f layoutFixture) inGroup(t *testing.T, ctx context.Context, conversationID string, who AccountDevice, joinedAfter, joinedEpoch int64) {
	t.Helper()
	if _, err := f.store.db.ExecContext(ctx, `INSERT OR IGNORE INTO conversation_mls_groups(conversation_id, epoch, updated_at) VALUES(?, 0, ?)`, conversationID, nowString()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `INSERT INTO conversation_mls_devices(conversation_id, device_id, account_id, joined_after_event_id, joined_epoch) VALUES(?, ?, ?, ?, ?)`,
		conversationID, who.Device.ID, who.Account.ID, joinedAfter, joinedEpoch); err != nil {
		t.Fatal(err)
	}
	// The commit that added the device produced its join epoch.
	f.atEpoch(t, ctx, conversationID, joinedEpoch)
}

// atEpoch raises the group's recorded epoch to at least epoch, as the MLS
// commit routes do.
func (f layoutFixture) atEpoch(t *testing.T, ctx context.Context, conversationID string, epoch int64) {
	t.Helper()
	if _, err := f.store.db.ExecContext(ctx, `UPDATE conversation_mls_groups SET epoch = MAX(epoch, ?) WHERE conversation_id = ?`, epoch, conversationID); err != nil {
		t.Fatal(err)
	}
}

func TestC7SealedBodyRuleAndReplay(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	route := f.epochMetadata(f.open.ID, 1, 1)
	for name, body := range map[string][]byte{
		"missing":       nil,
		"framing only":  c7Body(c7BodyFraming, 1),
		"off the block": c7Body(c7PostBytes+1, 1),
		"too large":     c7Body(c7MaxChannelBody+c7BodyBlock, 1),
		// A history_sync size is group-level only.
		"sync size in a channel": c7Body(c7PrivateSyncBytes, 1),
	} {
		if _, _, err := f.postBody(ctx, f.shared, f.member, "bad-"+name, route, body); !errors.Is(err, ErrInvalidSealedBody) {
			t.Errorf("%s: err = %v, want %v", name, err, ErrInvalidSealedBody)
		}
	}
	first, _, err := f.postBody(ctx, f.shared, f.member, "post", route, c7Body(c7PostBytes, 2))
	if err != nil {
		t.Fatalf("channel body: %v", err)
	}
	// A byte-identical retry answers with the stored envelope; a retry with
	// another body is a conflict.
	again, _, err := f.postBody(ctx, f.shared, f.member, "post", route, c7Body(c7PostBytes, 2))
	if err != nil || again.ID != first.ID {
		t.Fatalf("identical replay: id=%s err=%v", again.ID, err)
	}
	if _, _, err := f.postBody(ctx, f.shared, f.member, "post", route, c7Body(c7PostBytes, 3)); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("replay with another body: %v", err)
	}
	if _, _, err := f.postBody(ctx, f.shared, f.member, "post", route, nil); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("replay without its body: %v", err)
	}
	// Outside community conversations a body is refused.
	group, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.postBody(ctx, group.ID, f.owner, "group-body", f.metadata("", 0), c7Body(c7PostBytes, 1)); !errors.Is(err, ErrInvalidSealedBody) {
		t.Fatalf("body in a plain group: %v", err)
	}
	if _, _, err := f.postBody(ctx, group.ID, f.owner, "group-plain", f.metadata("", 0), nil); err != nil {
		t.Fatalf("plain group post: %v", err)
	}
	// Off, a body is refused everywhere.
	f.store.c7History = false
	if _, _, err := f.postBody(ctx, f.shared, f.member, "off", route, c7Body(c7PostBytes, 1)); !errors.Is(err, ErrInvalidSealedBody) {
		t.Fatalf("body with C7 off: %v", err)
	}
}

func TestC7BodiesRideOnSyncOnlyAndLegacyRoutesAnswerHistoryOnly(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	body := c7Body(c7PostBytes, 7)
	posted, event, err := f.postBody(ctx, f.shared, f.owner, "p", f.epochMetadata(f.open.ID, 1, 1), body)
	if err != nil {
		t.Fatal(err)
	}
	events, err := f.store.ListSyncEvents(ctx, f.member.Account.ID, f.member.Device.ID, event-1, 10)
	if err != nil {
		t.Fatal(err)
	}
	var served []byte
	for _, e := range events {
		if e.ID != event {
			continue
		}
		var payload struct {
			Envelope struct {
				SealedBody []byte `json:"sealed_body"`
			} `json:"envelope"`
		}
		if err := json.Unmarshal(e.Payload, &payload); err != nil {
			t.Fatal(err)
		}
		served = payload.Envelope.SealedBody
	}
	if !bytes.Equal(served, body) {
		t.Fatalf("sync served body %d bytes, want the stored %d", len(served), len(body))
	}
	// The stored sync event never holds the body.
	var stored []byte
	if err := f.store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, event).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(stored, []byte("sealed_body")) {
		t.Fatalf("sync_events stores the body: %s", stored)
	}
	if _, err := f.store.ListMessages(ctx, f.shared, f.member.Account.ID, ListMessagesOptions{}); !errors.Is(err, ErrHistoryRouteOnly) {
		t.Fatalf("legacy paging: %v", err)
	}
	if _, err := f.store.UpdateMessageEnvelope(ctx, posted.ID, f.owner.Account.ID, []byte("y"), "mls10-openmls-v1", f.epochMetadata(f.open.ID, 1, 1)); !errors.Is(err, ErrHistoryRouteOnly) {
		t.Fatalf("legacy edit: %v", err)
	}
	if _, err := f.store.DeleteMessageEnvelope(ctx, posted.ID, f.owner.Account.ID, []byte("y"), "mls10-openmls-v1", f.epochMetadata(f.open.ID, 1, 1)); !errors.Is(err, ErrHistoryRouteOnly) {
		t.Fatalf("legacy delete: %v", err)
	}
}

func TestC7HistoryFetchServesExactlyWhatTheJoinFilterWithheld(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	route := func(epoch int64) json.RawMessage { return f.epochMetadata(f.open.ID, 1, epoch) }
	before1, _, err := f.postBody(ctx, f.shared, f.owner, "b1", route(1), c7Body(c7PostBytes, 1))
	if err != nil {
		t.Fatal(err)
	}
	before2, joinedAfter, err := f.postBody(ctx, f.shared, f.owner, "b2", route(1), c7Body(c7PostBytes, 2))
	if err != nil {
		t.Fatal(err)
	}
	// A group-level history_sync before the join, in its own stream, for
	// the commit that produced epoch 1.
	f.atEpoch(t, ctx, f.shared, 1)
	sync, _, err := f.postBody(ctx, f.shared, f.owner, "hs", f.syncMetadata(EnvelopeC7SyncKey, 1, 1), c7Body(768+c7BodyFraming+c7SyncSlotBytes*2+256, 9))
	if err == nil {
		t.Fatalf("a body of no valid size was accepted: %s", sync.ID)
	}
	hs, _, err := f.postBody(ctx, f.shared, f.owner, "hs", f.syncMetadata(EnvelopeC7SyncKey, 1, 1), c7Body(c7PrivateSyncBytes, 9))
	if err != nil {
		t.Fatalf("group-level history_sync: %v", err)
	}
	// The member's device joins at epoch 2 after b2 and hs.
	var lastEvent int64
	if err := f.store.db.QueryRowContext(ctx, `SELECT MAX(id) FROM sync_events`).Scan(&lastEvent); err != nil {
		t.Fatal(err)
	}
	if lastEvent < joinedAfter {
		t.Fatalf("event order: %d < %d", lastEvent, joinedAfter)
	}
	f.inGroup(t, ctx, f.shared, f.member, lastEvent, 2)
	// Sent late at epoch 1 (withheld by the epoch filter), and at epoch 2.
	late, _, err := f.postBody(ctx, f.shared, f.owner, "late", route(1), c7Body(c7PostBytes, 3))
	if err != nil {
		t.Fatal(err)
	}
	live, liveEvent, err := f.postBody(ctx, f.shared, f.owner, "live", route(2), c7Body(c7PostBytes, 4))
	if err != nil {
		t.Fatal(err)
	}
	// Sync gives the member only the epoch-2 post.
	events, err := f.store.ListSyncEvents(ctx, f.member.Account.ID, f.member.Device.ID, lastEvent, 50)
	if err != nil {
		t.Fatal(err)
	}
	var synced []string
	for _, e := range events {
		if e.Type == "message.envelope.created" {
			var payload struct {
				MessageID string `json:"message_id"`
			}
			_ = json.Unmarshal(e.Payload, &payload)
			synced = append(synced, payload.MessageID)
		}
	}
	if len(synced) != 1 || synced[0] != live.ID {
		t.Fatalf("synced = %v, want only %s (event %d)", synced, live.ID, liveEvent)
	}
	ids := func(rows []HistoryBody) []string {
		out := []string{}
		for _, r := range rows {
			out = append(out, r.MessageID)
		}
		return out
	}
	same := func(got, want []string) bool {
		if len(got) != len(want) {
			return false
		}
		for i := range got {
			if got[i] != want[i] {
				return false
			}
		}
		return true
	}
	rows, err := f.store.ListHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.shared, f.open.ID, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{late.ID, before2.ID, before1.ID}; !same(ids(rows), want) {
		t.Fatalf("history = %v, want %v (newest first, the withheld ones only)", ids(rows), want)
	}
	if rows[0].Epoch == nil || *rows[0].Epoch != 1 || rows[0].ChannelID != f.open.ID || !bytes.Equal(rows[0].Body, c7Body(c7PostBytes, 3)) || rows[0].ActionID != "late" || rows[0].SenderDeviceID != f.owner.Device.ID {
		t.Fatalf("row = %+v", rows[0])
	}
	// Paging with before, and a limit.
	rows, err = f.store.ListHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.shared, f.open.ID, late.ID, 1)
	if err != nil || !same(ids(rows), []string{before2.ID}) {
		t.Fatalf("page before late = %v err=%v", ids(rows), err)
	}
	if _, err := f.store.ListHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.shared, f.open.ID, "msg_missing", 1); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("unknown before: %v", err)
	}
	// The group-level stream is its own.
	rows, err = f.store.ListHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.shared, "", "", 0)
	if err != nil || !same(ids(rows), []string{hs.ID}) {
		t.Fatalf("group-level history = %v err=%v", ids(rows), err)
	}
	// The owner was in the group from the start: sync gave it everything.
	rows, err = f.store.ListHistoryBodies(ctx, f.owner.Account.ID, f.owner.Device.ID, f.shared, f.open.ID, "", 0)
	if err != nil || len(rows) != 0 {
		t.Fatalf("owner history = %v err=%v", ids(rows), err)
	}
	// A hidden body is never served again.
	if _, err := f.store.HideHistoryMessage(ctx, before1.ID, f.owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	rows, err = f.store.ListHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.shared, f.open.ID, "", 0)
	if err != nil || !same(ids(rows), []string{late.ID, before2.ID}) {
		t.Fatalf("history after a hide = %v err=%v", ids(rows), err)
	}
	// Blocked senders are not served.
	if _, err := f.store.BlockAccount(ctx, f.member.Account.ID, f.owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	rows, err = f.store.ListHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.shared, f.open.ID, "", 0)
	if err != nil || len(rows) != 0 {
		t.Fatalf("history from a blocked sender = %v err=%v", ids(rows), err)
	}
	// Current member devices only.
	if _, err := f.store.ListHistoryBodies(ctx, f.outsider.Account.ID, f.outsider.Device.ID, f.shared, f.open.ID, "", 0); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider: %v", err)
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE conversation_mls_devices SET removed_after_event_id = ? WHERE device_id = ?`, liveEvent, f.member.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ListHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.shared, f.open.ID, "", 0); !errors.Is(err, ErrForbidden) {
		t.Fatalf("removed device: %v", err)
	}
	// Off, the route does not exist.
	f.store.c7History = false
	if _, err := f.store.ListHistoryBodies(ctx, f.owner.Account.ID, f.owner.Device.ID, f.shared, f.open.ID, "", 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("c7 off: %v", err)
	}
}

// The sync join filter reads any JSON integer as the epoch and the history
// fetch only non-negative ones; an epoch they would read differently is
// refused at write time, so a post is never both withheld and unserved.
func TestC7EpochMetadataIsANonNegativeInteger(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	for name, epoch := range map[string]string{
		"negative":     `-1`,
		"fraction":     `1.5`,
		"exponent":     `1e2`,
		"string":       `"3"`,
		"out of range": `9223372036854775808`,
		"null":         `null`,
	} {
		metadata := json.RawMessage(`{"protocol_version":1,"channel_id":"` + f.open.ID + `","community_layout_generation":1,"mls_epoch":` + epoch + `}`)
		if _, _, err := f.postBody(ctx, f.shared, f.member, "epoch-"+name, metadata, c7Body(c7PostBytes, 1)); !errors.Is(err, ErrInvalidEpochMetadata) {
			t.Errorf("%s epoch: err = %v, want %v", name, err, ErrInvalidEpochMetadata)
		}
	}
	// The same rule holds outside communities and with C7 off.
	f.store.c7History = false
	group, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.post(ctx, group.ID, f.owner, "neg", json.RawMessage(`{"mls_epoch":-4}`)); !errors.Is(err, ErrInvalidEpochMetadata) {
		t.Fatalf("negative epoch in a group: %v", err)
	}
	// A repeated key next to mls_epoch: Go reads the last value, SQLite's
	// json_extract the first.
	for _, metadata := range []string{`{"mls_epoch":-4,"mls_epoch":3}`, `{"mls_epoch":3,"mls_epoch":3}`, `{"mls_epoch":3,"protocol_version":1,"protocol_version":1}`} {
		if _, err := f.post(ctx, group.ID, f.owner, "dup"+metadata, json.RawMessage(metadata)); !errors.Is(err, ErrInvalidEpochMetadata) {
			t.Fatalf("repeated key %s: %v", metadata, err)
		}
	}
	for _, metadata := range []string{`{"mls_epoch":0}`, `{"mls_epoch":12}`, `{"protocol_version":1}`} {
		if _, err := f.post(ctx, group.ID, f.owner, "ok"+metadata, json.RawMessage(metadata)); err != nil {
			t.Fatalf("%s: %v", metadata, err)
		}
	}
}

func TestC7FormerMemberKeysAndHistoryHideRules(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.inGroup(t, ctx, f.shared, f.member, 0, 0)
	route := f.epochMetadata(f.open.ID, 1, 1)
	byMember, event, err := f.postBody(ctx, f.shared, f.member, "m", route, c7Body(c7PostBytes, 1))
	if err != nil {
		t.Fatal(err)
	}
	byOwner, _, err := f.postBody(ctx, f.shared, f.owner, "o", route, c7Body(c7PostBytes, 2))
	if err != nil {
		t.Fatal(err)
	}
	// Nobody has left: no former member keys.
	keys, err := f.store.ListFormerMemberKeys(ctx, f.owner.Account.ID, f.owner.Device.ID, f.shared)
	if err != nil || len(keys) != 0 {
		t.Fatalf("keys with nobody gone = %+v err=%v", keys, err)
	}
	// A member may not hide another's post; the sender may hide its own.
	if _, err := f.store.HideHistoryMessage(ctx, byOwner.ID, f.member.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member hides the owner's post: %v", err)
	}
	if _, err := f.store.HideHistoryMessage(ctx, byMember.ID, f.outsider.Account.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider hide: %v", err)
	}
	if conversation, err := f.store.HideHistoryMessage(ctx, byOwner.ID, f.owner.Account.ID); err != nil || conversation != f.shared {
		t.Fatalf("own hide: %s %v", conversation, err)
	}
	moderation := func() int {
		var n int
		if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM moderation_events WHERE action = ? AND actor_account_id = ? AND target_account_id = ?`, ModerationMessageHidden, f.owner.Account.ID, f.member.Account.ID).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if moderation() != 0 {
		t.Fatal("an own hide is not a moderation event")
	}
	// The owner moderates the member's post: hidden and audited once.
	for i := 0; i < 2; i++ {
		if _, err := f.store.HideHistoryMessage(ctx, byMember.ID, f.owner.Account.ID); err != nil {
			t.Fatalf("moderator hide %d: %v", i, err)
		}
	}
	if got := moderation(); got != 1 {
		t.Fatalf("moderation events = %d, want 1", got)
	}
	var hidden int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM envelope_bodies WHERE history_hidden = 1`).Scan(&hidden); err != nil || hidden != 2 {
		t.Fatalf("hidden bodies = %d err=%v", hidden, err)
	}
	// The member's device leaves the group: its key is a former member's,
	// to current member devices only.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE conversation_mls_devices SET removed_after_event_id = ? WHERE device_id = ?`, event, f.member.Device.ID); err != nil {
		t.Fatal(err)
	}
	keys, err = f.store.ListFormerMemberKeys(ctx, f.owner.Account.ID, f.owner.Device.ID, f.shared)
	if err != nil || len(keys) != 1 || keys[0].DeviceID != f.member.Device.ID || keys[0].AccountID != f.member.Account.ID || len(keys[0].SigningKey) != 32 || keys[0].Revoked {
		t.Fatalf("former member keys = %+v err=%v", keys, err)
	}
	if _, err := f.store.ListFormerMemberKeys(ctx, f.member.Account.ID, f.member.Device.ID, f.shared); !errors.Is(err, ErrForbidden) {
		t.Fatalf("a removed device reads former keys: %v", err)
	}
	if _, err := f.store.ListFormerMemberKeys(ctx, f.outsider.Account.ID, f.outsider.Device.ID, f.shared); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider reads former keys: %v", err)
	}
}

func TestC7GroupLevelExemptionIsOnlyForHistorySyncSizes(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	if _, err := f.store.ManageConversationMember(ctx, f.privateConv, f.owner.Account.ID, f.member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := f.store.SetChannelSlowMode(ctx, f.community.ID, f.private.ID, f.owner.Account.ID, time.Hour); err != nil {
		t.Fatalf("slow mode on the private channel: %v", err)
	}
	private := f.epochMetadata(f.private.ID, 1, 1)
	// The member's device joined the private group at epoch 1.
	f.inGroup(t, ctx, f.privateConv, f.member, 0, 1)
	f.inGroup(t, ctx, f.shared, f.member, 0, 1)
	request := f.syncMetadata(EnvelopeC7SyncRequestKey, 1, 1)
	if _, _, err := f.postBody(ctx, f.privateConv, f.member, "post1", private, c7Body(c7PostBytes, 1)); err != nil {
		t.Fatalf("first post: %v", err)
	}
	// Slow mode holds a second post naming the channel.
	if _, _, err := f.postBody(ctx, f.privateConv, f.member, "post2", private, c7Body(c7PostBytes, 1)); !errors.Is(err, ErrSlowMode) {
		t.Fatalf("second post in slow mode: %v", err)
	}
	// Leaving out the channel keys does not skip it for a body of channel
	// size: the server cannot tell a post from a history_sync_request. A
	// group-level envelope must say which type it is, so an untagged one is
	// refused and a tagged request takes the posting checks.
	if _, _, err := f.postBody(ctx, f.privateConv, f.member, "disguised", f.epochMetadata("", 0, 1), c7Body(c7PostBytes, 1)); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("untagged group-level post: %v", err)
	}
	if _, _, err := f.postBody(ctx, f.privateConv, f.member, "disguised", request, c7Body(c7PostBytes, 1)); !errors.Is(err, ErrSlowMode) {
		t.Fatalf("channel-sized group-level request: %v", err)
	}
	// One-channel history_sync bodies pass slow mode, one per epoch.
	f.atEpoch(t, ctx, f.privateConv, 2)
	for i, key := range []string{"sync1", "sync2"} {
		if _, _, err := f.postBody(ctx, f.privateConv, f.member, key, f.syncMetadata(EnvelopeC7SyncKey, 2, int64(i+1)), c7Body(c7PrivateSyncBytes, 1)); err != nil {
			t.Fatalf("member history_sync %s: %v", key, err)
		}
	}
	// A private group names only its own channel.
	if _, _, err := f.postBody(ctx, f.privateConv, f.owner, "foreign", f.epochMetadata(f.open.ID, 1, 1), c7Body(c7PostBytes, 1)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("a private group naming an open channel: %v", err)
	}
	// In the shared group an announcement channel still refuses a member,
	// while the member's history_sync (no channel) passes.
	if _, _, err := f.postBody(ctx, f.shared, f.member, "news", f.epochMetadata(f.announcement.ID, 1, 1), c7Body(c7PostBytes, 1)); !errors.Is(err, ErrPostingRestricted) {
		t.Fatalf("member post in the announcement channel: %v", err)
	}
	if _, _, err := f.postBody(ctx, f.shared, f.member, "shared-sync", f.syncMetadata(EnvelopeC7SyncKey, 1, 1), c7Body(c7PrivateSyncBytes, 1)); err != nil {
		t.Fatalf("member history_sync in the shared group: %v", err)
	}
}
