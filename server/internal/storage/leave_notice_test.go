package storage

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

func leaveMetadata(base json.RawMessage, value interface{}) json.RawMessage {
	var fields map[string]interface{}
	_ = json.Unmarshal(base, &fields)
	if fields == nil {
		fields = map[string]interface{}{}
	}
	fields[EnvelopeLeaveNoticeKey] = value
	raw, _ := json.Marshal(fields)
	return raw
}

// A governing member's own leave proof passes the announcement rule, a
// timeout and slow mode; the mark carries nothing else and is bounded.
func TestLeaveNoticePassesPostingRulesInTheSharedGroup(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	notice := leaveMetadata(f.metadata(f.announcement.ID, 1), true)
	// Unmarked, the member's post in the announcement channel is refused.
	if _, err := f.post(ctx, f.shared, f.member, "plain", f.metadata(f.announcement.ID, 1)); !errors.Is(err, ErrPostingRestricted) {
		t.Fatalf("unmarked post: %v", err)
	}
	// Timed out and in slow mode as well.
	if _, err := f.store.SetMemberTimeout(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := f.store.SetChannelSlowMode(ctx, f.community.ID, f.announcement.ID, f.owner.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "open", f.metadata(f.open.ID, 1)); !errors.Is(err, ErrTimedOut) {
		t.Fatalf("timed-out post: %v", err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "leave1", notice); err != nil {
		t.Fatalf("leave notice refused: %v", err)
	}
	// Its retry answers and does not count twice; a second notice (the
	// signed statement, ABI 24) is allowed. A leave that did not go through
	// may be tried again at once, so its two notices pass too (review LOW:
	// with two an hour, a cancelled leave kept the member from leaving for
	// an hour). A fifth inside the interval is refused.
	if _, err := f.post(ctx, f.shared, f.member, "leave1", notice); err != nil {
		t.Fatalf("leave notice replay: %v", err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "leave2", notice); err != nil {
		t.Fatalf("second notice: %v", err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "retry1", notice); err != nil {
		t.Fatalf("the retried leave's notice: %v", err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "retry2", notice); err != nil {
		t.Fatalf("the retried leave's signed notice: %v", err)
	}
	_, err := f.post(ctx, f.shared, f.member, "leave2b", notice)
	var limited LeaveNoticeLimitedError
	if !errors.Is(err, ErrLeaveNoticeLimited) || !errors.As(err, &limited) || limited.Wait <= 0 || limited.Wait > LeaveNoticeInterval {
		t.Fatalf("fifth notice: %v wait=%v", err, limited.Wait)
	}
	// The wait runs from the oldest notice in the window.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE memberships SET created_at = ? WHERE conversation_id = ? AND account_id = ?`, formatTime(time.Now().Add(-2*LeaveNoticeInterval)), f.shared, f.member.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE message_envelopes SET created_at = ? WHERE sender_account_id = ? AND idempotency_key = ?`, formatTime(time.Now().Add(-3*LeaveNoticeInterval/4)), f.member.Account.ID, "leave1"); err != nil {
		t.Fatal(err)
	}
	_, err = f.post(ctx, f.shared, f.member, "leave2c", notice)
	if !errors.As(err, &limited) || limited.Wait < LeaveNoticeInterval/4-time.Minute || limited.Wait > LeaveNoticeInterval/4+time.Minute {
		t.Fatalf("wait from the oldest: %v wait=%v", err, limited.Wait)
	}
	// Once the interval is over, another is allowed.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE message_envelopes SET created_at = ? WHERE sender_account_id = ?`, formatTime(time.Now().Add(-2*LeaveNoticeInterval)), f.member.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "leave3", notice); err != nil {
		t.Fatalf("notice after the interval: %v", err)
	}
}

func TestLeaveNoticeMarkIsNarrow(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	base := f.metadata(f.announcement.ID, 1)
	for _, value := range []interface{}{false, 1, "true", map[string]interface{}{}} {
		if _, err := f.post(ctx, f.shared, f.member, "bad", leaveMetadata(base, value)); !errors.Is(err, ErrInvalidChannelRoute) {
			t.Fatalf("mark %v: %v", value, err)
		}
	}
	// A repeated key is refused: with an epoch by the epoch rule (review
	// L2), which runs first, and without one by the mark's own rule.
	repeated := json.RawMessage(`{"protocol_version":1,"mls_epoch":1,"channel_id":"` + f.announcement.ID + `","community_layout_generation":1,"c4_leave":true,"c4_leave":true}`)
	if _, err := f.post(ctx, f.shared, f.member, "rep", repeated); !errors.Is(err, ErrInvalidEpochMetadata) {
		t.Fatalf("repeated mark with an epoch: %v", err)
	}
	repeated = json.RawMessage(`{"protocol_version":1,"channel_id":"` + f.announcement.ID + `","community_layout_generation":1,"c4_leave":true,"c4_leave":true}`)
	if _, err := f.post(ctx, f.shared, f.member, "rep2", repeated); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("repeated mark: %v", err)
	}
	// Nothing rides along: no franking commitment, no reply or thread.
	marked := leaveMetadata(base, true)
	for name, envelope := range map[string]domain.MessageEnvelope{
		"franked": {FrankCommit: []byte("c")},
		"thread":  {ThreadRootID: func() *string { s := "msg_x"; return &s }()},
	} {
		envelope.ConversationID = f.shared
		envelope.SenderAccountID = f.member.Account.ID
		envelope.SenderDeviceID = f.member.Device.ID
		envelope.IdempotencyKey = "k_" + name
		envelope.Ciphertext = []byte("x")
		envelope.CryptoProtocol = "mls-openmls-todo"
		envelope.CryptoMetadata = marked
		if _, _, err := f.store.SaveMessageEnvelope(ctx, envelope); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	// A private channel's group carries no record: no leave notice there.
	if _, err := f.post(ctx, f.privateConv, f.owner, "priv", leaveMetadata(json.RawMessage(`{"protocol_version":1}`), true)); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("private channel group: %v", err)
	}
}

func TestLeaveNoticeInAnAdminsOnlyGroupAndNotInADM(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	moderator := registerTestMember(t, ctx, store, invite.Code, "moderator")
	group, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.AddConversationMember(ctx, group.ID, moderator.Account.ID, domain.RoleModerator); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.SetConversationPostingPolicy(ctx, group.ID, owner.Account.ID, PostingPolicyAdmins); err != nil {
		t.Fatal(err)
	}
	post := func(conversationID, key string, metadata json.RawMessage) error {
		_, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
			ConversationID: conversationID, SenderAccountID: moderator.Account.ID, SenderDeviceID: moderator.Device.ID,
			IdempotencyKey: key, Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo", CryptoMetadata: metadata,
		})
		return err
	}
	if err := post(group.ID, "m1", json.RawMessage(`{"protocol_version":1}`)); !errors.Is(err, ErrPostingRestricted) {
		t.Fatalf("moderator post in admins-only group: %v", err)
	}
	if err := post(group.ID, "m2", json.RawMessage(`{"protocol_version":1,"c4_leave":true}`)); err != nil {
		t.Fatalf("moderator leave notice: %v", err)
	}
	dm, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{moderator.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if err := post(dm.ID, "d1", json.RawMessage(`{"protocol_version":1,"c4_leave":true}`)); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("dm leave notice: %v", err)
	}
}
