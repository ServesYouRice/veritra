package storage

import (
	"context"
	"errors"
	"testing"
	"time"
)

// W6: a timed mute ends by itself, both when it is read and when push targets
// are chosen, with no job and no write at the end time.
func TestTimedMuteEndsByItself(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	peer := registerTestMember(t, ctx, store, invite.Code, "mutepeer")
	group, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{peer.Account.ID},
	})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}
	if _, err := store.CreatePushSubscription(ctx, peer.Account.ID, peer.Device.ID, "fcm", "fcm-token-0123456789-0123456789-0123456789", "", ""); err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	targets := func() int {
		t.Helper()
		found, err := store.PushTargetsForConversation(ctx, group.ID, owner.Account.ID)
		if err != nil {
			t.Fatalf("targets: %v", err)
		}
		return len(found)
	}
	if targets() != 1 {
		t.Fatalf("unmuted member should be a push target")
	}

	until := time.Now().Add(2 * time.Hour)
	if err := store.SetConversationNotificationMute(ctx, group.ID, peer.Account.ID, true, &until); err != nil {
		t.Fatalf("mute: %v", err)
	}
	mute, err := store.ConversationNotificationMute(ctx, group.ID, peer.Account.ID)
	if err != nil || !mute.Muted || mute.Until == nil || mute.Until.Unix() != until.Unix() {
		t.Fatalf("mute=%+v err=%v", mute, err)
	}
	if targets() != 0 {
		t.Fatalf("a muted member is not a push target")
	}

	// The same row, with an end that has passed: unmuted without any write.
	if _, err := store.db.ExecContext(ctx, `UPDATE conversation_notification_preferences SET muted_until = ?`, time.Now().Add(-time.Minute).Unix()); err != nil {
		t.Fatalf("expire: %v", err)
	}
	mute, err = store.ConversationNotificationMute(ctx, group.ID, peer.Account.ID)
	if err != nil || mute.Muted || mute.Until != nil {
		t.Fatalf("expired mute=%+v err=%v", mute, err)
	}
	if targets() != 1 {
		t.Fatalf("an expired mute should wake the member again")
	}

	// An end must be in the future and not absurdly far.
	for _, bad := range []time.Time{time.Now().Add(-time.Minute), time.Now().Add(MaxMuteDuration + time.Hour)} {
		if err := store.SetConversationNotificationMute(ctx, group.ID, peer.Account.ID, true, &bad); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("mute until %v: err=%v, want ErrInvalidInput", bad, err)
		}
	}

	// Always: no end.
	if err := store.SetConversationNotificationMute(ctx, group.ID, peer.Account.ID, true, nil); err != nil {
		t.Fatalf("mute always: %v", err)
	}
	mute, _ = store.ConversationNotificationMute(ctx, group.ID, peer.Account.ID)
	if !mute.Muted || mute.Until != nil || targets() != 0 {
		t.Fatalf("always mute=%+v", mute)
	}
	if err := store.SetConversationNotificationMute(ctx, group.ID, peer.Account.ID, false, &until); err != nil {
		t.Fatalf("unmute: %v", err)
	}
	mute, _ = store.ConversationNotificationMute(ctx, group.ID, peer.Account.ID)
	if mute.Muted || mute.Until != nil || targets() != 1 {
		t.Fatalf("unmuted=%+v", mute)
	}
}
