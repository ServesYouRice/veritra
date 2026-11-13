package storage

import (
	"context"
	"errors"
	"testing"

	"private-messenger/server/internal/domain"
)

// Review L-6 and its residual: a move request that repeats the actor's own
// latest move with the same request id answers that move again, storing and
// publishing nothing. The account alone never makes a replay: a second
// device of the same admin (its own request id, or none) is refused, so it
// cannot adopt the first device's move and set the new group up twice. A
// request id whose move the channel has moved on from is refused and moves
// nothing.
func TestC3MoveReplayAnswersTheSameMove(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	count := func(query string, args ...interface{}) int {
		t.Helper()
		var n int
		if err := f.store.db.QueryRowContext(ctx, query, args...).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	const (
		deviceA = "device-a-move-000000000001"
		deviceB = "device-b-move-000000000001"
		backA   = "device-a-move-000000000002"
	)
	moved, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID, deviceA)
	if err != nil {
		t.Fatal(err)
	}
	if moved.Replayed || moved.Move.MovedBy != f.owner.Account.ID || moved.Move.RequestID != deviceA {
		t.Fatalf("first move = %+v", moved)
	}
	moves := count(`SELECT COUNT(*) FROM c3_channel_moves`)
	events := count(`SELECT COUNT(*) FROM sync_events`)
	unchanged := func(what string) {
		t.Helper()
		if count(`SELECT COUNT(*) FROM c3_channel_moves`) != moves || count(`SELECT COUNT(*) FROM sync_events`) != events {
			t.Fatalf("%s stored a move or an event", what)
		}
	}
	again, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID, deviceA)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if !again.Replayed || again.Move != moved.Move || again.Conversation.ID != moved.Move.ToConversationID ||
		again.FromEventID != 0 || again.ToEventID != 0 {
		t.Fatalf("replay = %+v, want %+v", again, moved)
	}
	unchanged("a replay")
	// The same account's other device, with its own id or none: refused.
	for _, request := range []string{deviceB, ""} {
		if _, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID, request); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("same account, request %q: %v", request, err)
		}
	}
	unchanged("another device's repeat")
	// Another admin with the first device's id is not a replay either.
	if _, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.member.Account.ID, deviceA); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("another admin's repeat: %v", err)
	}
	// The id asking for the other direction is refused, not a new move.
	if _, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessOpen, f.owner.Account.ID, deviceA); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("the id for the other direction: %v", err)
	}
	unchanged("a mismatched replay")
	// A malformed id is refused.
	if _, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessOpen, f.owner.Account.ID, "short"); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("malformed id: %v", err)
	}
	// Back to open; its replay too.
	back, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessOpen, f.owner.Account.ID, backA)
	if err != nil || back.Replayed {
		t.Fatalf("move back = %+v %v", back, err)
	}
	if again, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessOpen, f.owner.Account.ID, backA); err != nil || !again.Replayed ||
		again.Move.ToConversationID != f.shared || again.Conversation.Kind != CommunityShared {
		t.Fatalf("replay of the move back = %+v %v", again, err)
	}
	// The first id, retried late after the move back, moves nothing.
	moves = count(`SELECT COUNT(*) FROM c3_channel_moves`)
	events = count(`SELECT COUNT(*) FROM sync_events`)
	if _, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID, deviceA); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("a late retry of an earlier move: %v", err)
	}
	unchanged("a late retry")
	// A channel that never moved has nothing to replay.
	if _, err := f.store.MoveChannel(ctx, f.announcement.ID, ChannelAccessOpen, f.owner.Account.ID, deviceA); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("never moved: %v", err)
	}
	// The id is stored with its move only.
	if n := count(`SELECT COUNT(*) FROM sync_events WHERE payload_json LIKE ?`, "%device-a-move%"); n != 0 {
		t.Fatalf("%d events carry a request id", n)
	}
}

// Review L-8: an announcement channel made private and then open again is
// an announcement channel; a channel created private comes out open, and
// "announcement" is taken as asked.
func TestC3MoveBackKeepsThePostingMode(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	route := func(channelID string) (string, string) {
		t.Helper()
		var access, kind string
		if err := f.store.db.QueryRowContext(ctx, `SELECT r.access_mode, ch.kind FROM community_channel_routes r JOIN channels ch ON ch.id = r.channel_id WHERE r.channel_id = ?`, channelID).Scan(&access, &kind); err != nil {
			t.Fatal(err)
		}
		return access, kind
	}
	if _, err := f.store.MoveChannel(ctx, f.announcement.ID, ChannelAccessPrivate, f.owner.Account.ID, ""); err != nil {
		t.Fatal(err)
	}
	back, err := f.store.MoveChannel(ctx, f.announcement.ID, ChannelAccessOpen, f.owner.Account.ID, "")
	if err != nil || back.Move.ToAccess != ChannelAccessAnnouncement {
		t.Fatalf("move back = %+v %v", back, err)
	}
	if access, kind := route(f.announcement.ID); access != ChannelAccessAnnouncement || kind != "announcement" {
		t.Fatalf("route after the move back = %s %s", access, kind)
	}
	if _, err := f.store.MoveChannel(ctx, f.private.ID, ChannelAccessOpen, f.owner.Account.ID, ""); err != nil {
		t.Fatal(err)
	}
	if access, _ := route(f.private.ID); access != ChannelAccessOpen {
		t.Fatalf("a channel created private = %s", access)
	}
	if _, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID, ""); err != nil {
		t.Fatal(err)
	}
	if moved, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessAnnouncement, f.owner.Account.ID, ""); err != nil || moved.Move.ToAccess != ChannelAccessAnnouncement {
		t.Fatalf("asked for announcement = %+v %v", moved, err)
	}
}

// Review L-4: the moved-keys route lists only the devices with a body the
// moved-history route serves: the channel's stream or the group-level one,
// up to the move's cutoff.
func TestC3MovedMemberKeysAreScopedToTheMovedStreams(t *testing.T) {
	ctx := context.Background()
	f := newC7Fixture(t, ctx)
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	second, _, err := f.store.CreateChannelWithConversation(ctx, f.community.ID, "", f.owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	f.inGroup(t, ctx, f.shared, f.owner, 0, 0)
	f.inGroup(t, ctx, f.shared, f.member, 0, 0)
	f.inGroup(t, ctx, f.shared, f.outsider, 0, 0)
	f.atEpoch(t, ctx, f.shared, 1)
	if _, _, err := f.postBody(ctx, f.shared, f.owner, "in-channel", f.epochMetadata(f.open.ID, 1, 1), c7Body(c7PostBytes, 1)); err != nil {
		t.Fatal(err)
	}
	// The member posts only in another channel.
	if _, _, err := f.postBody(ctx, f.shared, f.member, "elsewhere", f.epochMetadata(second.ID, second.LayoutGeneration, 1), c7Body(c7PostBytes, 2)); err != nil {
		t.Fatal(err)
	}
	moved, err := f.store.MoveChannel(ctx, f.open.ID, ChannelAccessPrivate, f.owner.Account.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	// The third device's only body, group-level, is past the cutoff.
	if _, _, err := f.postBody(ctx, f.shared, f.outsider, "late", f.syncMetadata(EnvelopeC7SyncRequestKey, 1, 0), c7Body(c7PostBytes, 3)); err != nil {
		t.Fatal(err)
	}
	private := moved.Move.ToConversationID
	if err := f.store.AddConversationMember(ctx, private, f.member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	f.inGroup(t, ctx, private, f.member, moved.ToEventID, 1)
	keys, err := f.store.ListMovedMemberKeys(ctx, f.member.Account.ID, f.member.Device.ID, f.open.ID, f.shared)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0].DeviceID != f.owner.Device.ID {
		t.Fatalf("keys = %+v, want only the owner's device", keys)
	}
}
