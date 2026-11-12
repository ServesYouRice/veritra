package storage

import (
	"context"
	"errors"
	"testing"

	"private-messenger/server/internal/domain"
)

// C3 channel conversion (C7 decision 11): who may move a channel, what the
// move re-routes, and what the destination's members may read of the old
// conversation.
func TestC3ChannelMoveRoutesAndMovedHistory(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.atEpoch(t, ctx, f.shared, 1)
	route := func(epoch int64) []byte { return f.epochMetadata(f.open.ID, 1, epoch) }
	before, _, err := f.postBody(ctx, f.shared, f.owner, "before", route(1), c7Body(c7PostBytes, 1))
	if err != nil {
		t.Fatal(err)
	}
	other, _, err := f.postBody(ctx, f.shared, f.owner, "other", f.epochMetadata(f.announcement.ID, 1, 1), c7Body(c7PostBytes, 2))
	if err != nil {
		t.Fatal(err)
	}
	f.membershipEpoch(t, ctx, f.shared, 1)
	hs, _, err := f.postBody(ctx, f.shared, f.owner, "hs", f.syncMetadata(EnvelopeC7SyncKey, 1, 1), c7Body(c7PrivateSyncBytes, 9))
	if err != nil {
		t.Fatal(err)
	}

	// Refusals: a plain member, a non-member, the same kind, no channel.
	for name, tc := range map[string]struct {
		channel, access, actor string
		want                   error
	}{
		"member":       {f.open.ID, ChannelAccessPrivate, f.member.Account.ID, ErrForbidden},
		"outsider":     {f.open.ID, ChannelAccessPrivate, f.outsider.Account.ID, ErrNotMember},
		"same kind":    {f.open.ID, ChannelAccessAnnouncement, f.owner.Account.ID, ErrInvalidInput},
		"unknown kind": {f.open.ID, "secret", f.owner.Account.ID, ErrInvalidInput},
		"no channel":   {"chan_missing", ChannelAccessPrivate, f.owner.Account.ID, ErrNotFound},
	} {
		if _, err := f.store.MoveChannel(ctx, tc.channel, tc.access, tc.actor); !errors.Is(err, tc.want) {
			t.Fatalf("%s: err=%v, want %v", name, err, tc.want)
		}
	}

	// Open to private: a new conversation with the owner alone.
	moved, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	private := moved.Move.ToConversationID
	if moved.Move.FromConversationID != f.shared || private == f.shared || moved.Conversation.ID != private ||
		moved.Move.FromAccess != ChannelAccessOpen || moved.FromEventID <= 0 || moved.ToEventID <= moved.FromEventID {
		t.Fatalf("move = %+v", moved)
	}
	var routed, access string
	if err := f.store.db.QueryRowContext(ctx, `SELECT conversation_id, access_mode FROM community_channel_routes WHERE channel_id = ?`, f.open.ID).Scan(&routed, &access); err != nil || routed != private || access != ChannelAccessPrivate {
		t.Fatalf("route = %s %s %v", routed, access, err)
	}
	if member, err := f.store.IsConversationMember(ctx, private, f.owner.Account.ID); err != nil || !member {
		t.Fatalf("owner not in the new conversation: %v", err)
	}
	var events int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events WHERE event_type = ? AND conversation_id IN (?, ?)`, ChannelMovedEventType, f.shared, private).Scan(&events); err != nil || events != 2 {
		t.Fatalf("moved events = %d %v", events, err)
	}
	// The old conversation refuses the channel now; the new one routes it.
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "late", route(1), c7Body(c7PostBytes, 3)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("post to the old route: %v", err)
	}
	// The same request again is a replay (review L-6): the same move.
	if again, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID); err != nil || !again.Replayed || again.Move.ToConversationID != private {
		t.Fatalf("second move to private: %+v %v", again, err)
	}
	// A history_sync of the old group after the move is past the cutoff.
	f.membershipEpoch(t, ctx, f.shared, 2)
	f.atEpoch(t, ctx, f.shared, 2)
	after, _, err := f.postBody(ctx, f.shared, f.owner, "hs-after", f.syncMetadata(EnvelopeC7SyncKey, 2, 2), c7Body(c7PrivateSyncBytes, 8))
	if err != nil {
		t.Fatal(err)
	}

	// The member reads only as a group device of the new conversation.
	read := func(stream string) ([]HistoryBody, error) {
		return f.store.ListMovedHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.open.ID, f.shared, stream, "", 0)
	}
	if _, err := read(f.open.ID); !errors.Is(err, ErrNotMember) {
		t.Fatalf("not a member yet: %v", err)
	}
	if err := f.store.AddConversationMember(ctx, private, f.member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if _, err := read(f.open.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("not in the group yet: %v", err)
	}
	f.inGroup(t, ctx, private, f.member, moved.ToEventID, 1)
	ids := func(bodies []HistoryBody, err error) []string {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		out := []string{}
		for _, body := range bodies {
			out = append(out, body.MessageID)
		}
		return out
	}
	if got := ids(read(f.open.ID)); len(got) != 1 || got[0] != before.ID {
		t.Fatalf("channel stream = %v, want only %s (not %s)", got, before.ID, other.ID)
	}
	if got := ids(read("")); len(got) != 1 || got[0] != hs.ID {
		t.Fatalf("group-level stream = %v, want %s and not %s", got, hs.ID, after.ID)
	}
	if _, err := read(f.announcement.ID); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("another channel's stream: %v", err)
	}
	if _, err := f.store.ListMovedHistoryBodies(ctx, f.member.Account.ID, f.member.Device.ID, f.open.ID, f.privateConv, "", "", 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a conversation the channel never left: %v", err)
	}
	keys, err := f.store.ListMovedMemberKeys(ctx, f.member.Account.ID, f.member.Device.ID, f.open.ID, f.shared)
	if err != nil || len(keys) != 1 || keys[0].DeviceID != f.owner.Device.ID {
		t.Fatalf("keys = %+v %v", keys, err)
	}
	// Off, the routes are not found.
	f.store.c7History = false
	if _, err := read(f.open.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("c7 off: %v", err)
	}
	f.store.c7History = true

	// Back to open: the shared conversation's group reads the private one.
	inPrivate, _, err := f.postBody(ctx, private, f.member, "in-private", f.epochMetadata(f.open.ID, 1, 1), c7Body(c7PostBytes, 5))
	if err != nil {
		t.Fatal(err)
	}
	back, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessOpen, f.owner.Account.ID)
	if err != nil || back.Move.ToConversationID != f.shared || back.Move.FromConversationID != private {
		t.Fatalf("move back = %+v %v", back, err)
	}
	if _, _, err := f.postBody(ctx, private, f.member, "late-private", f.epochMetadata(f.open.ID, 1, 1), c7Body(c7PostBytes, 6)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("post to the old private route: %v", err)
	}
	got := ids(f.store.ListMovedHistoryBodies(ctx, f.owner.Account.ID, f.owner.Device.ID, f.open.ID, private, f.open.ID, "", 0))
	if len(got) != 1 || got[0] != inPrivate.ID {
		t.Fatalf("private stream after the move back = %v", got)
	}
	// The channel left the shared conversation once; its rows there are
	// still readable from the shared group, up to that first cutoff.
	if got := ids(f.store.ListMovedHistoryBodies(ctx, f.owner.Account.ID, f.owner.Device.ID, f.open.ID, f.shared, f.open.ID, "", 0)); len(got) != 1 || got[0] != before.ID {
		t.Fatalf("shared stream from the shared group = %v", got)
	}
}
