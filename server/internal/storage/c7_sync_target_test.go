package storage

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

// C7 targeted history_sync (owner answer Q3): recipients by join epoch, the
// sender's sibling device excluded, push wakes for the newcomers only, the
// history route still serving it to a later newcomer and never to an
// existing member, and the key refused anywhere else.
func TestC7TargetedHistorySyncStorage(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	const ownerTablet = "dev-owner-tablet"
	const memberTablet = "dev-member-tablet"
	addTestDevice(t, ctx, f.store, f.owner.Account.ID, ownerTablet)
	addTestDevice(t, ctx, f.store, f.member.Account.ID, memberTablet)
	// The owner and its tablet from the start; the member's phone joined at
	// epoch 1; the member's tablet is the newcomer at epoch 2.
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.inGroup(t, ctx, f.shared, AccountDevice{Account: f.owner.Account, Device: domain.Device{ID: ownerTablet}}, 0, 0)
	f.inGroup(t, ctx, f.shared, f.member, 0, 1)
	var joinedAfter int64
	if err := f.store.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM sync_events`).Scan(&joinedAfter); err != nil {
		t.Fatal(err)
	}
	tablet := AccountDevice{Account: f.member.Account, Device: domain.Device{ID: memberTablet}}
	f.inGroup(t, ctx, f.shared, tablet, joinedAfter, 2)
	for _, sub := range []struct{ id, account, device string }{
		{"psub_phone", f.member.Account.ID, f.member.Device.ID},
		{"psub_tablet", f.member.Account.ID, memberTablet},
		{"psub_owner_tablet", f.owner.Account.ID, ownerTablet},
	} {
		if _, err := f.store.db.ExecContext(ctx, `INSERT INTO push_subscriptions(id, account_id, device_id, provider, endpoint, created_at) VALUES (?, ?, ?, 'fcm', ?, ?)`,
			sub.id, sub.account, sub.device, "https://push.invalid/"+sub.id, nowString()); err != nil {
			t.Fatal(err)
		}
	}
	sync, event, recipients, err := saveWithRecipients(ctx, f, f.shared, f.owner, "hs", f.syncMetadata(EnvelopeC7SyncKey, 2, 2), c7Body(c7PrivateSyncBytes, 5))
	if err != nil {
		t.Fatal(err)
	}
	if len(recipients) != 2 || recipients[0] > recipients[1] {
		t.Fatalf("recipients = %v, want the owner (echo) and the member (newcomer's account)", recipients)
	}
	for _, r := range recipients {
		if r != f.owner.Account.ID && r != f.member.Account.ID {
			t.Fatalf("recipients = %v", recipients)
		}
	}
	// Sync: the newcomer and the sender, never the member's phone or the
	// sender's tablet.
	for device, want := range map[string]bool{memberTablet: true, f.owner.Device.ID: true, f.member.Device.ID: false, ownerTablet: false} {
		account := f.member.Account.ID
		if device == f.owner.Device.ID || device == ownerTablet {
			account = f.owner.Account.ID
		}
		events, err := f.store.ListSyncEvents(ctx, account, device, event-1, 10)
		if err != nil {
			t.Fatal(err)
		}
		got := false
		for _, e := range events {
			got = got || e.ID == event
		}
		if got != want {
			t.Fatalf("device %s synced the history_sync: %v, want %v", device, got, want)
		}
	}
	// Push: only the newcomer's subscription is woken.
	rows, err := f.store.db.QueryContext(ctx, `SELECT subscription_id FROM push_wake_jobs WHERE sync_event_id = ?`, event)
	if err != nil {
		t.Fatal(err)
	}
	var woken []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		woken = append(woken, id)
	}
	rows.Close()
	if len(woken) != 1 || woken[0] != "psub_tablet" {
		t.Fatalf("push wakes = %v, want only the newcomer's", woken)
	}
	// The history route: an existing member never gets it; a later newcomer
	// (the owner's tablet re-added at epoch 3) does, in the group-level stream.
	for _, who := range []AccountDevice{f.member, tablet} {
		got, err := f.store.ListHistoryBodies(ctx, who.Account.ID, who.Device.ID, f.shared, "", "", 0)
		if err != nil || len(got) != 0 {
			t.Fatalf("history for %s = %v err=%v", who.Device.ID, got, err)
		}
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE conversation_mls_devices SET joined_after_event_id = ?, joined_epoch = 3 WHERE device_id = ?`, event, ownerTablet); err != nil {
		t.Fatal(err)
	}
	got, err := f.store.ListHistoryBodies(ctx, f.owner.Account.ID, ownerTablet, f.shared, "", "", 0)
	if err != nil || len(got) != 1 || got[0].MessageID != sync.ID {
		t.Fatalf("history for a later newcomer = %v err=%v", got, err)
	}
	// A request is not targeted: every member gets it, and its realtime
	// recipients are every member.
	_, requestEvent, requestRecipients, err := saveWithRecipients(ctx, f, f.shared, tablet, "rq", f.syncMetadata(EnvelopeC7SyncRequestKey, 2, 2), c7Body(c7PostBytes, 6))
	if err != nil {
		t.Fatal(err)
	}
	if len(requestRecipients) != 2 {
		t.Fatalf("request recipients = %v", requestRecipients)
	}
	if events, err := f.store.ListSyncEvents(ctx, f.member.Account.ID, f.member.Device.ID, requestEvent-1, 10); err != nil || len(events) == 0 || events[0].ID != requestEvent {
		t.Fatalf("member's sync of the request = %v err=%v", events, err)
	}
}

func TestC7HistorySyncKeyIsRefusedOutsideGroupLevelC7(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.atEpoch(t, ctx, f.shared, 1)
	sync := c7Body(c7PrivateSyncBytes, 1)
	withRoute := func(key string, value interface{}) json.RawMessage {
		raw, _ := json.Marshal(map[string]interface{}{EnvelopeChannelKey: f.open.ID, EnvelopeLayoutGenerationKey: 1, "mls_epoch": 1, key: value})
		return raw
	}
	raw := func(s string) json.RawMessage { return json.RawMessage(s) }
	for name, metadata := range map[string]json.RawMessage{
		"on a channel post":     withRoute(EnvelopeC7SyncKey, 1),
		"request on a post":     withRoute(EnvelopeC7SyncRequestKey, 0),
		"both keys":             raw(`{"mls_epoch":1,"c7_sync_for_epoch":1,"c7_sync_request_for_epoch":0}`),
		"negative":              raw(`{"mls_epoch":1,"c7_sync_for_epoch":-1}`),
		"a string":              raw(`{"mls_epoch":1,"c7_sync_for_epoch":"1"}`),
		"a float":               raw(`{"mls_epoch":1,"c7_sync_for_epoch":1.0}`),
		"untagged":              raw(`{"mls_epoch":1}`),
		"sync key on a request": raw(`{"mls_epoch":1,"c7_sync_for_epoch":1}`),
	} {
		body := sync
		if name == "on a channel post" || name == "request on a post" || name == "sync key on a request" {
			body = c7Body(c7PostBytes, 1)
		}
		if _, _, err := f.postBody(ctx, f.shared, f.owner, "k-"+name, metadata, body); !errors.Is(err, ErrInvalidHistorySyncTarget) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// No commit has produced epoch 4 yet: a history_sync claiming it would
	// make the committer's real one look delivered when the commit comes.
	f.atEpoch(t, ctx, f.shared, 3)
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "future", raw(`{"mls_epoch":3,"c7_sync_for_epoch":4}`), sync); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("a history_sync for a future epoch: %v", err)
	}
	if delivered, err := f.store.HistorySyncDelivered(ctx, f.owner.Account.ID, f.owner.Device.ID, f.shared, 4); err != nil || delivered {
		t.Fatalf("future epoch after the refusal: delivered=%v err=%v", delivered, err)
	}
	// Review M3: only an epoch a commit adding or removing a device
	// produced may be named; epoch 3 came from a self-update so far.
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "no-membership", raw(`{"mls_epoch":3,"c7_sync_for_epoch":3}`), sync); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("a history_sync for an epoch no membership commit produced: %v", err)
	}
	// The current epoch is accepted even when no device joined at it (a
	// removal-only commit's history_sync, kept for later walks; owner,
	// 2026-11-12: keep sending and storing them).
	f.membershipEpoch(t, ctx, f.shared, 3)
	// Review H2: sent in an epoch before the one it names, the I51 join
	// filter would withhold it from the very newcomer it answers.
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "early", raw(`{"mls_epoch":2,"c7_sync_for_epoch":3}`), sync); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("a history_sync declared below its epoch: %v", err)
	}
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "no-epoch", raw(`{"c7_sync_for_epoch":3}`), sync); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("a history_sync with no declared epoch: %v", err)
	}
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "removal-only", raw(`{"mls_epoch":3,"c7_sync_for_epoch":3}`), sync); err != nil {
		t.Fatalf("a removal-only history_sync at the current epoch: %v", err)
	}
	// A repeated key is refused before routing (the stored row would be read
	// differently by Go and SQLite).
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "repeated", raw(`{"mls_epoch":1,"c7_sync_for_epoch":2,"c7_sync_for_epoch":1}`), sync); !errors.Is(err, ErrInvalidEpochMetadata) && !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Errorf("repeated: %v", err)
	}
	// A conversation outside the C0 layout (a plain group) refuses the key.
	group, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID, MemberAccountIDs: []string{f.member.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.postBody(ctx, group.ID, f.owner, "plain", raw(`{"mls_epoch":1,"c7_sync_for_epoch":1}`), nil); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("outside the layout: %v", err)
	}
	// A layout group with no roster cannot be targeted.
	if _, _, err := f.postBody(ctx, f.privateConv, f.owner, "no-roster", raw(`{"mls_epoch":1,"c7_sync_for_epoch":1}`), sync); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("no roster: %v", err)
	}
	// With C7 off the key is refused too.
	f.store.c7History = false
	if _, _, err := f.postBody(ctx, group.ID, f.owner, "off", raw(`{"mls_epoch":1,"c7_sync_for_epoch":1}`), nil); !errors.Is(err, ErrInvalidHistorySyncTarget) {
		t.Fatalf("c7 off: %v", err)
	}
	if _, err := f.store.HistorySyncDelivered(ctx, f.owner.Account.ID, f.owner.Device.ID, f.shared, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("c7 off check: %v", err)
	}
}

// saveWithRecipients sends a two-part envelope as the HTTP route does and
// returns it with its sync event and live recipients.
func saveWithRecipients(ctx context.Context, f layoutFixture, conversationID string, who AccountDevice, key string, metadata json.RawMessage, body []byte) (domain.MessageEnvelope, int64, []string, error) {
	envelope, _, event, recipients, err := f.store.SaveMessageEnvelopeWithSyncEventAndRecipients(ctx, domain.MessageEnvelope{
		ConversationID: conversationID, SenderAccountID: who.Account.ID, SenderDeviceID: who.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("reference"), CryptoProtocol: "mls10-openmls-v1",
		CryptoMetadata: metadata, SealedBody: body,
	})
	return envelope, event, recipients, err
}

// Review H2 (owner answer "Newcomer keeps asking"): a junk history_sync
// stored first marks the epoch delivered, so the honest committer's is
// refused; the newcomer's request reopens the epoch and the honest one is
// accepted and reaches it. Requests from one device for one epoch are
// spaced by the newcomer's backoff (review L3).
func TestC7NewcomerKeepsAskingPastAJunkHistorySync(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	const newcomer = "dev-member-tablet"
	addTestDevice(t, ctx, f.store, f.member.Account.ID, newcomer)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.inGroup(t, ctx, f.shared, f.member, 0, 1)
	var joinedAfter int64
	if err := f.store.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM sync_events`).Scan(&joinedAfter); err != nil {
		t.Fatal(err)
	}
	tablet := AccountDevice{Account: f.member.Account, Device: domain.Device{ID: newcomer}}
	f.inGroup(t, ctx, f.shared, tablet, joinedAfter, 2)
	syncAt2 := f.syncMetadata(EnvelopeC7SyncKey, 2, 2)
	// The member's phone sends junk first.
	junk, _, err := f.postBody(ctx, f.shared, f.member, "junk", syncAt2, c7Body(c7PrivateSyncBytes, 1))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "honest-1", syncAt2, c7Body(c7PrivateSyncBytes, 2)); !errors.Is(err, ErrHistorySyncDelivered) {
		t.Fatalf("honest history_sync before a request: %v", err)
	}
	request := f.syncMetadata(EnvelopeC7SyncRequestKey, 2, 2)
	if _, _, err := f.postBody(ctx, f.shared, tablet, "ask-1", request, c7Body(c7PostBytes, 3)); err != nil {
		t.Fatalf("first request: %v", err)
	}
	honest, honestEvent, err := f.postBody(ctx, f.shared, f.owner, "honest-2", syncAt2, c7Body(c7PrivateSyncBytes, 4))
	if err != nil {
		t.Fatalf("honest history_sync after the request: %v", err)
	}
	events, err := f.store.ListSyncEvents(ctx, f.member.Account.ID, newcomer, joinedAfter, 50)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, e := range events {
		var payload struct {
			MessageID string `json:"message_id"`
		}
		_ = json.Unmarshal(e.Payload, &payload)
		got[payload.MessageID] = true
	}
	if !got[junk.ID] || !got[honest.ID] {
		t.Fatalf("newcomer synced %v, want both the junk %s and the honest %s (event %d)", got, junk.ID, honest.ID, honestEvent)
	}
	// Asking again at once is refused; after the backoff it is accepted
	// and reopens the epoch again.
	if _, _, err := f.postBody(ctx, f.shared, tablet, "ask-2", request, c7Body(c7PostBytes, 5)); !errors.Is(err, ErrHistorySyncRequestTooSoon) {
		t.Fatalf("a second request at once: %v", err)
	}
	backdate := func(by time.Duration) {
		if _, err := f.store.db.ExecContext(ctx, `UPDATE message_envelopes SET created_at = ? WHERE sender_device_id = ? AND idempotency_key LIKE 'ask-%'`,
			formatTime(time.Now().UTC().Add(-by)), newcomer); err != nil {
			t.Fatal(err)
		}
	}
	backdate(c7RequestSpacing(1) + time.Second)
	if _, _, err := f.postBody(ctx, f.shared, tablet, "ask-2", request, c7Body(c7PostBytes, 5)); err != nil {
		t.Fatalf("a second request after a minute: %v", err)
	}
	// With two sent, the third waits about two minutes, not one.
	backdate(c7RequestSpacing(1) + time.Second)
	if _, _, err := f.postBody(ctx, f.shared, tablet, "ask-3", request, c7Body(c7PostBytes, 6)); !errors.Is(err, ErrHistorySyncRequestTooSoon) {
		t.Fatalf("a third request one minute later: %v", err)
	}
	backdate(c7RequestSpacing(2) + time.Second)
	if _, _, err := f.postBody(ctx, f.shared, tablet, "ask-3", request, c7Body(c7PostBytes, 6)); err != nil {
		t.Fatalf("a third request after two minutes: %v", err)
	}
	if delivered, err := f.store.HistorySyncDelivered(ctx, f.owner.Account.ID, f.owner.Device.ID, f.shared, 2); err != nil || delivered {
		t.Fatalf("after the third request: delivered=%v err=%v", delivered, err)
	}
	if c7RequestSpacing(40) != time.Hour*9/10 {
		t.Fatalf("spacing cap = %v", c7RequestSpacing(40))
	}
}

// Review L1: a C7 envelope's declared mls_epoch lies between its sender
// device's joined_epoch and the group's recorded epoch.
func TestC7DeclaredEpochMustBeOneTheSenderIsIn(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.inGroup(t, ctx, f.shared, f.member, 0, 3)
	f.atEpoch(t, ctx, f.shared, 5)
	for epoch, want := range map[int64]error{2: ErrEpochOutOfRange, 3: nil, 5: nil, 6: ErrEpochOutOfRange} {
		_, _, err := f.postBody(ctx, f.shared, f.member, "e"+strconv.FormatInt(epoch, 10), f.epochMetadata(f.open.ID, 1, epoch), c7Body(c7PostBytes, byte(epoch)))
		if !errors.Is(err, want) && !(want == nil && err == nil) {
			t.Errorf("epoch %d: err = %v, want %v", epoch, err, want)
		}
	}
}

// Review L-9: in a group the server tracks, a sender device with no live
// roster row (removed, or never added) declares no epoch it is in; a
// conversation whose group the server does not track is left alone.
func TestC7DeclaredEpochNeedsALiveRosterRow(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.atEpoch(t, ctx, f.shared, 2)
	// Never added to the shared group.
	if _, _, err := f.postBody(ctx, f.shared, f.member, "absent", f.epochMetadata(f.open.ID, 1, 1), c7Body(c7PostBytes, 1)); !errors.Is(err, ErrEpochOutOfRange) {
		t.Fatalf("a device not in the roster: %v", err)
	}
	// Removed from it.
	f.inGroup(t, ctx, f.shared, f.member, 0, 1)
	if _, _, err := f.postBody(ctx, f.shared, f.member, "live", f.epochMetadata(f.open.ID, 1, 2), c7Body(c7PostBytes, 2)); err != nil {
		t.Fatalf("a live roster device: %v", err)
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE conversation_mls_devices SET removed_after_event_id = 1 WHERE conversation_id = ? AND device_id = ?`, f.shared, f.member.Device.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.postBody(ctx, f.shared, f.member, "removed", f.epochMetadata(f.open.ID, 1, 2), c7Body(c7PostBytes, 3)); !errors.Is(err, ErrEpochOutOfRange) {
		t.Fatalf("a removed device: %v", err)
	}
	// No tracked group: allowed as before.
	if _, _, err := f.postBody(ctx, f.privateConv, f.owner, "untracked", f.epochMetadata(f.private.ID, 1, 4), c7Body(c7PostBytes, 4)); err != nil {
		t.Fatalf("an untracked group: %v", err)
	}
}

// Residual (d): a history_sync whose sealed body0 or any slot is all zero
// bytes is junk (each part is AEAD output, never all zero when sealed
// honestly). It is refused before it can mark the newcomer's epoch
// delivered, so the honest committer's sync still goes through.
func TestC7AllZeroHistorySyncRefused(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.inGroup(t, ctx, f.shared, f.member, 0, 1)
	syncAt1 := f.syncMetadata(EnvelopeC7SyncKey, 1, 1)
	// A two-channel body: P(2) = 768, + 124, then two 700-byte slots.
	const twoChannels = 768 + c7BodyFraming + 2*c7SyncSlotBytes
	if c7SyncChannels(twoChannels) != 2 {
		t.Fatalf("size %d is not a two-channel history_sync", twoChannels)
	}
	zeroed := func(from, to int) []byte {
		body := c7Body(twoChannels, 9)
		for i := from; i < to; i++ {
			body[i] = 0
		}
		return body
	}
	slot1 := twoChannels - 2*c7SyncSlotBytes
	slot2 := twoChannels - c7SyncSlotBytes
	for name, body := range map[string][]byte{
		"whole body":  make([]byte, twoChannels),
		"body0":       zeroed(0, slot1),
		"first slot":  zeroed(slot1, slot2),
		"last slot":   zeroed(slot2, twoChannels),
		"one-channel": make([]byte, c7PrivateSyncBytes),
	} {
		if _, _, err := f.postBody(ctx, f.shared, f.owner, "zero-"+strings.ReplaceAll(name, " ", "-"), syncAt1, body); !errors.Is(err, ErrInvalidHistorySyncTarget) {
			t.Fatalf("%s: err = %v, want ErrInvalidHistorySyncTarget", name, err)
		}
	}
	// Zero bytes inside a part, short of the whole part, are ciphertext like
	// any other.
	partly := zeroed(slot1+1, twoChannels)
	partly[twoChannels-1] = 1
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "honest", syncAt1, partly); err != nil {
		t.Fatalf("a sync with no all-zero part, after the refused ones: %v", err)
	}
}
