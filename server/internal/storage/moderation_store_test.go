package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

func (f inviteFixture) post(t *testing.T, ctx context.Context, who AccountDevice, key string) error {
	t.Helper()
	_, _, err := f.store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID: f.conv.ID, SenderAccountID: who.Account.ID, SenderDeviceID: who.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo",
	})
	return err
}

func (f inviteFixture) addMember(t *testing.T, ctx context.Context, who AccountDevice, role string) {
	t.Helper()
	if _, err := f.store.ManageCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, who.Account.ID, role); err != nil {
		t.Fatalf("add %s: %v", who.Account.Username, err)
	}
}

func TestKickAndBanRankRules(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.addMember(t, ctx, alice, domain.RoleModerator)
	f.addMember(t, ctx, bob, domain.RoleMember)

	// A member cannot kick; a moderator cannot kick a peer, an admin or itself.
	if _, err := f.store.KickCommunityMember(ctx, f.comm.ID, bob.Account.ID, f.member.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member kicks: %v", err)
	}
	if _, err := f.store.KickCommunityMember(ctx, f.comm.ID, alice.Account.ID, f.admin.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("moderator kicks admin: %v", err)
	}
	if _, err := f.store.BanCommunityMember(ctx, f.comm.ID, alice.Account.ID, alice.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("self ban: %v", err)
	}
	// A moderator kicks a member: out of the community and the channel, and it
	// may be added again.
	if _, err := f.store.KickCommunityMember(ctx, f.comm.ID, alice.Account.ID, bob.Account.ID); err != nil {
		t.Fatalf("moderator kicks member: %v", err)
	}
	if _, err := f.store.CommunityMemberRole(ctx, f.comm.ID, bob.Account.ID); err == nil {
		t.Fatal("kicked member is still in")
	}
	f.addMember(t, ctx, bob, domain.RoleMember)
	// A moderator may not ban a non-member (needs an admin).
	if _, err := f.store.BanCommunityMember(ctx, f.comm.ID, alice.Account.ID, f.people[2].Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("moderator pre-bans: %v", err)
	}
}

func TestBanRemovesRefusesReturnAndUnbanDoesNotReadd(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.addMember(t, ctx, alice, domain.RoleMember)
	if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("channel member: %v", err)
	}
	f.invite(t, ctx, f.communityTarget(), f.admin, testLocator(7), 9)

	removal, err := f.store.BanCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID)
	if err != nil || len(removal.Channels) != 1 {
		t.Fatalf("ban: %+v err=%v", removal, err)
	}
	if _, err := f.store.CommunityMemberRole(ctx, f.comm.ID, alice.Account.ID); err == nil {
		t.Fatal("banned account is still a community member")
	}
	if member, _ := f.store.IsConversationMember(ctx, f.conv.ID, alice.Account.ID); member {
		t.Fatal("banned account is still in the channel")
	}
	// No way back: add, channel add, join request.
	if _, err := f.store.ManageCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("add banned account: %v", err)
	}
	if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("add banned account to channel: %v", err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(7)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("banned account requests to join: %v", err)
	}
	// Banning again is idempotent; the list names it; the audit log has it.
	if _, err := f.store.BanCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID); err != nil && !errors.Is(err, ErrNotFound) && !errors.Is(err, ErrForbidden) {
		t.Fatalf("second ban: %v", err)
	}
	bans, err := f.store.ListCommunityBans(ctx, f.comm.ID, f.admin.Account.ID)
	if err != nil || len(bans) != 1 || bans[0].AccountID != alice.Account.ID {
		t.Fatalf("bans = %+v err=%v", bans, err)
	}
	if _, err := f.store.ListCommunityBans(ctx, f.comm.ID, f.member.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member lists bans: %v", err)
	}
	// Unban deletes the row and re-adds nothing.
	if err := f.store.UnbanCommunityMember(ctx, f.comm.ID, f.member.Account.ID, alice.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member unbans: %v", err)
	}
	if err := f.store.UnbanCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("unban: %v", err)
	}
	if _, err := f.store.CommunityMemberRole(ctx, f.comm.ID, alice.Account.ID); err == nil {
		t.Fatal("unban re-added the account")
	}
	if err := f.store.UnbanCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unban twice: %v", err)
	}
	f.addMember(t, ctx, alice, domain.RoleMember)
	// An admin may ban someone who already left; a moderator may not.
	bob := f.people[1]
	if _, err := f.store.BanCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, bob.Account.ID); err != nil {
		t.Fatalf("admin bans a non-member: %v", err)
	}
	if _, err := f.store.ManageCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, bob.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("add pre-banned account: %v", err)
	}
	events, err := f.store.ListModerationEvents(ctx, f.comm.ID, f.admin.Account.ID, 50)
	if err != nil || len(events) < 4 {
		t.Fatalf("events = %+v err=%v", events, err)
	}
	if events[len(events)-1].Action != ModerationBan || events[len(events)-1].Target != alice.Account.ID {
		t.Fatalf("oldest event = %+v", events[len(events)-1])
	}
	if _, err := f.store.ListModerationEvents(ctx, f.comm.ID, f.member.Account.ID, 10); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member reads the audit log: %v", err)
	}
}

func TestTimeoutRefusesPostsUntilItEnds(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.addMember(t, ctx, alice, domain.RoleMember)
	if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := f.post(t, ctx, alice, "a1"); err != nil {
		t.Fatalf("post before: %v", err)
	}
	for _, bad := range []time.Duration{-time.Second, domain.MaxTimeout + time.Second} {
		if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, bad); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("timeout %v: %v", bad, err)
		}
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.member.Account.ID, alice.Account.ID, time.Hour); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member times out member: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, f.owner.Account.ID, time.Hour); !errors.Is(err, ErrForbidden) {
		t.Fatalf("admin times out owner: %v", err)
	}
	until, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour)
	if err != nil || until == nil {
		t.Fatalf("timeout: %v %v", until, err)
	}
	if err := f.post(t, ctx, alice, "a2"); !errors.Is(err, ErrTimedOut) {
		t.Fatalf("post while timed out: %v", err)
	}
	// A retry of the post stored before the timeout still answers (replay).
	if err := f.post(t, ctx, alice, "a1"); err != nil {
		t.Fatalf("replay while timed out: %v", err)
	}
	if err := f.post(t, ctx, f.member, "m1"); err != nil {
		t.Fatalf("someone else posts: %v", err)
	}
	// It ends by itself, and an admin can lift it early.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE memberships SET timeout_until = ? WHERE community_id = ? AND account_id = ?`, formatTime(time.Now().Add(-time.Minute)), f.comm.ID, alice.Account.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.post(t, ctx, alice, "a3"); err != nil {
		t.Fatalf("post after it ended: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, 0); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if err := f.post(t, ctx, alice, "a4"); err != nil {
		t.Fatalf("post after clearing: %v", err)
	}
}

func TestSlowModeGapsNonModeratorsOnly(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.addMember(t, ctx, alice, domain.RoleMember)
	if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	var channelID string
	if err := f.store.db.QueryRowContext(ctx, `SELECT channel_id FROM conversations WHERE id = ?`, f.conv.ID).Scan(&channelID); err != nil {
		t.Fatal(err)
	}
	if err := f.store.SetChannelSlowMode(ctx, f.comm.ID, channelID, f.member.Account.ID, time.Minute); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member sets slow mode: %v", err)
	}
	for _, bad := range []time.Duration{-time.Second, domain.MaxSlowMode + time.Second, 1500 * time.Millisecond} {
		if err := f.store.SetChannelSlowMode(ctx, f.comm.ID, channelID, f.admin.Account.ID, bad); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("slow mode %v: %v", bad, err)
		}
	}
	if err := f.store.SetChannelSlowMode(ctx, f.comm.ID, "chan_missing", f.admin.Account.ID, time.Minute); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown channel: %v", err)
	}
	if err := f.store.SetChannelSlowMode(ctx, f.comm.ID, channelID, f.admin.Account.ID, time.Hour); err != nil {
		t.Fatalf("set slow mode: %v", err)
	}
	if err := f.post(t, ctx, alice, "s1"); err != nil {
		t.Fatalf("first post: %v", err)
	}
	err := f.post(t, ctx, alice, "s2")
	var slow SlowModeError
	if !errors.Is(err, ErrSlowMode) || !errors.As(err, &slow) || slow.Wait <= 0 || slow.Wait > time.Hour {
		t.Fatalf("second post: %v wait=%v", err, slow.Wait)
	}
	// Moderators and above are exempt; another member has its own gap.
	for i := 0; i < 3; i++ {
		if err := f.post(t, ctx, f.admin, fmt.Sprintf("adm%d", i)); err != nil {
			t.Fatalf("admin post %d: %v", i, err)
		}
	}
	if err := f.post(t, ctx, f.member, "mem1"); err != nil {
		t.Fatalf("other member: %v", err)
	}
	// The gap passes, or an admin turns slow mode off.
	if _, err := f.store.db.ExecContext(ctx, `UPDATE message_envelopes SET created_at = ? WHERE sender_account_id = ?`, formatTime(time.Now().Add(-2*time.Hour)), alice.Account.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.post(t, ctx, alice, "s3"); err != nil {
		t.Fatalf("post after the gap: %v", err)
	}
	if err := f.post(t, ctx, alice, "s4"); !errors.Is(err, ErrSlowMode) {
		t.Fatalf("post right after: %v", err)
	}
	if err := f.store.SetChannelSlowMode(ctx, f.comm.ID, channelID, f.admin.Account.ID, 0); err != nil {
		t.Fatal(err)
	}
	if err := f.post(t, ctx, alice, "s5"); err != nil {
		t.Fatalf("post with slow mode off: %v", err)
	}
}

func TestPausedInvitesRefuseUseUntilResumed(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.invite(t, ctx, f.communityTarget(), f.admin, testLocator(3), 9)
	if _, err := f.store.SetInvitesPaused(ctx, f.comm.ID, f.member.Account.ID, time.Hour); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member pauses: %v", err)
	}
	if _, err := f.store.SetInvitesPaused(ctx, f.comm.ID, f.admin.Account.ID, domain.MaxTimeout+time.Second); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("too long: %v", err)
	}
	if _, err := f.store.SetInvitesPaused(ctx, f.comm.ID, f.admin.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(3)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("request while paused: %v", err)
	}
	if _, err := f.store.PreviewMembershipInvite(ctx, alice.Account.ID, testLocator(3)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("preview while paused: %v", err)
	}
	// A group's invitation is not a community's.
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(4), 9)
	if _, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(4)); err != nil {
		t.Fatalf("group invite while community paused: %v", err)
	}
	if _, err := f.store.SetInvitesPaused(ctx, f.comm.ID, f.admin.Account.ID, 0); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(3)); err != nil {
		t.Fatalf("request after resume: %v", err)
	}
}

func TestTimeoutAlsoStopsEditsAndReactions(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.addMember(t, ctx, alice, domain.RoleMember)
	if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	message, _, err := f.store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID: f.conv.ID, SenderAccountID: alice.Account.ID, SenderDeviceID: alice.Device.ID,
		IdempotencyKey: "e1", Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.UpdateMessageEnvelope(ctx, message.ID, alice.Account.ID, []byte("y"), "mls-openmls-todo", nil); !errors.Is(err, ErrTimedOut) {
		t.Fatalf("edit while timed out: %v", err)
	}
	if err := f.store.CreateReaction(ctx, message.ID, alice.Account.ID, []byte("r")); !errors.Is(err, ErrTimedOut) {
		t.Fatalf("reaction while timed out: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, 0); err != nil {
		t.Fatal(err)
	}
	if err := f.store.CreateReaction(ctx, message.ID, alice.Account.ID, []byte("r")); err != nil {
		t.Fatalf("reaction after clearing: %v", err)
	}
}

func TestModeratorCannotLiftBansAndBannedSeesNoPreview(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.addMember(t, ctx, alice, domain.RoleModerator)
	f.addMember(t, ctx, bob, domain.RoleMember)
	f.invite(t, ctx, f.communityTarget(), f.admin, testLocator(8), 9)
	if _, err := f.store.BanCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, bob.Account.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.store.UnbanCommunityMember(ctx, f.comm.ID, alice.Account.ID, bob.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("moderator unbans: %v", err)
	}
	if _, err := f.store.PreviewMembershipInvite(ctx, bob.Account.ID, testLocator(8)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("banned account previews: %v", err)
	}
	if _, err := f.store.PreviewMembershipInvite(ctx, f.people[2].Account.ID, testLocator(8)); err != nil {
		t.Fatalf("someone else previews: %v", err)
	}
}

func TestModerationStateHidesPrivateChannelsFromNonMembers(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleModerator); err != nil {
		t.Fatal(err)
	}
	has := func(state ModerationState, id string) bool {
		for _, c := range state.Channels {
			if c.ChannelID == id {
				return true
			}
		}
		return false
	}
	moderator, err := f.store.GetModerationState(ctx, f.community.ID, f.member.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !has(moderator, f.open.ID) || !has(moderator, f.announcement.ID) || has(moderator, f.private.ID) {
		t.Fatalf("moderator outside the private channel sees %+v", moderator.Channels)
	}
	owner, err := f.store.GetModerationState(ctx, f.community.ID, f.owner.Account.ID)
	if err != nil || !has(owner, f.private.ID) {
		t.Fatalf("a member of the private channel sees %+v err=%v", owner.Channels, err)
	}
	if _, err := f.store.GetModerationState(ctx, f.community.ID, f.outsider.Account.ID); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider: %v", err)
	}
}

// C5 known gap closed (migration 0095): leaving, or being kicked, and joining
// again does not end a timeout early; lifting it ends it for good.
func TestTimeoutSurvivesLeaveKickAndRejoin(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	join := func() {
		t.Helper()
		f.addMember(t, ctx, alice, domain.RoleMember)
		if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
			t.Fatalf("channel member: %v", err)
		}
	}
	join()
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	// Leave and come back: still timed out.
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, alice.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("leave: %v", err)
	}
	join()
	if err := f.post(t, ctx, alice, "after-rejoin"); !errors.Is(err, ErrTimedOut) {
		t.Fatalf("post after leaving and rejoining: %v", err)
	}
	// Kicked and added back: still timed out.
	if _, err := f.store.KickCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("kick: %v", err)
	}
	join()
	if err := f.post(t, ctx, alice, "after-kick"); !errors.Is(err, ErrTimedOut) {
		t.Fatalf("post after kick and re-add: %v", err)
	}
	// Lifted: gone for good, also across a later rejoin.
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, alice.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("leave: %v", err)
	}
	join()
	if err := f.post(t, ctx, alice, "after-lift"); err != nil {
		t.Fatalf("post after the timeout was lifted: %v", err)
	}
	// Another community's member row is not touched by this one's timeout.
	var other int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE account_id = ? AND community_id IS NULL AND timeout_until IS NOT NULL`, alice.Account.ID).Scan(&other); err != nil || other != 0 {
		t.Fatalf("conversation rows with a timeout: %d err=%v", other, err)
	}
}

// Owner decision 2026-11-21: while invitations are paused the admins still
// see the pending requests and can decline them; approving stays refused
// until the pause ends.
func TestPausedInvitesStillListAndDeclineRequests(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.invite(t, ctx, f.communityTarget(), f.admin, testLocator(5), 9)
	aliceRequest, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(5))
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	bobRequest, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(5))
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	list := func() []domain.JoinRequest {
		t.Helper()
		requests, err := f.store.ListJoinRequests(ctx, f.communityTarget(), f.admin.Account.ID)
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		return requests
	}
	if got := list(); len(got) != 2 {
		t.Fatalf("before pause: %+v", got)
	}
	if paused, err := f.store.CommunityInvitesPausedUntil(ctx, f.communityTarget()); err != nil || paused != nil {
		t.Fatalf("paused before pause = %v err=%v", paused, err)
	}
	if _, err := f.store.SetInvitesPaused(ctx, f.comm.ID, f.admin.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if got := list(); len(got) != 2 {
		t.Fatalf("while paused: %+v", got)
	}
	if paused, err := f.store.CommunityInvitesPausedUntil(ctx, f.communityTarget()); err != nil || paused == nil {
		t.Fatalf("paused = %v err=%v", paused, err)
	}
	if paused, err := f.store.CommunityInvitesPausedUntil(ctx, f.groupTarget()); err != nil || paused != nil {
		t.Fatalf("a group is never paused: %v err=%v", paused, err)
	}
	// Approving stays refused; declining works.
	if _, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, aliceRequest.ID, true); !errors.Is(err, ErrMembershipInviteUnavailable) {
		t.Fatalf("approve while paused: %v", err)
	}
	if _, err := f.store.CommunityMemberRole(ctx, f.comm.ID, alice.Account.ID); err == nil {
		t.Fatal("approved while paused")
	}
	decision, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, bobRequest.ID, false)
	if err != nil || !decision.Changed || decision.Request.Status != domain.JoinRequestRejected {
		t.Fatalf("decline while paused: %+v err=%v", decision, err)
	}
	if got := list(); len(got) != 1 || got[0].AccountID != alice.Account.ID {
		t.Fatalf("after decline: %+v", got)
	}
	if _, err := f.store.SetInvitesPaused(ctx, f.comm.ID, f.admin.Account.ID, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, aliceRequest.ID, true); err != nil {
		t.Fatalf("approve after resume: %v", err)
	}
}

// Owner decision 2026-11-21: an admin lifts the timeout of someone who left,
// so the rejoin does not bring it back. Moderators may not, a running
// timeout must exist, and a non-member is never given a new one.
func TestAdminLiftsDepartedMembersTimeout(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, mod := f.people[0], f.people[1]
	f.addMember(t, ctx, alice, domain.RoleMember)
	f.addMember(t, ctx, mod, domain.RoleModerator)
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, alice.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("leave: %v", err)
	}
	departed, err := f.store.ListDepartedTimeouts(ctx, f.comm.ID, f.admin.Account.ID)
	if err != nil || len(departed) != 1 || departed[0].AccountID != alice.Account.ID || departed[0].Username != alice.Account.Username {
		t.Fatalf("departed = %+v err=%v", departed, err)
	}
	if _, err := f.store.ListDepartedTimeouts(ctx, f.comm.ID, f.member.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member lists: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, mod.Account.ID, alice.Account.ID, 0); !errors.Is(err, ErrForbidden) {
		t.Fatalf("moderator lifts: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.people[2].Account.ID, alice.Account.ID, 0); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider lifts: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour); !errors.Is(err, ErrNotFound) {
		t.Fatalf("new timeout on a non-member: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, 0); err != nil {
		t.Fatalf("admin lifts: %v", err)
	}
	if departed, err := f.store.ListDepartedTimeouts(ctx, f.comm.ID, f.admin.Account.ID); err != nil || len(departed) != 0 {
		t.Fatalf("departed after lift = %+v err=%v", departed, err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("lift twice: %v", err)
	}
	events, err := f.store.ListModerationEvents(ctx, f.comm.ID, f.admin.Account.ID, 10)
	if err != nil || len(events) == 0 || events[0].Action != ModerationTimeoutCleared || events[0].Target != alice.Account.ID {
		t.Fatalf("audit = %+v err=%v", events, err)
	}
	// Rejoining now starts without a timeout.
	f.addMember(t, ctx, alice, domain.RoleMember)
	if err := f.post(t, ctx, alice, "after-lift"); err != nil {
		t.Fatalf("post after rejoin: %v", err)
	}
	// An admin of another community neither sees nor lifts this one's
	// remembered timeouts, even where it runs a community of its own.
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour); err != nil {
		t.Fatalf("time out again: %v", err)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, alice.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("leave again: %v", err)
	}
	carol := f.people[2]
	other, err := f.store.CreateCommunity(ctx, carol.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ListDepartedTimeouts(ctx, f.comm.ID, carol.Account.ID); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outside admin lists: %v", err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, other.ID, carol.Account.ID, alice.Account.ID, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("lift through another community: %v", err)
	}
	if departed, err := f.store.ListDepartedTimeouts(ctx, f.comm.ID, f.admin.Account.ID); err != nil || len(departed) != 1 {
		t.Fatalf("departed after outside attempts = %+v err=%v", departed, err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, 0); err != nil {
		t.Fatalf("lift: %v", err)
	}
	// An expired remembered timeout cannot be lifted (nothing to lift).
	if _, err := f.store.db.ExecContext(ctx, `INSERT INTO member_timeouts(community_id, account_id, timeout_until) VALUES(?, ?, ?)`, f.comm.ID, f.people[2].Account.ID, formatTime(time.Now().UTC().Add(-time.Minute))); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, f.people[2].Account.ID, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("lift an expired one: %v", err)
	}
}

// C5: a banned account's devices cannot be claimed for an add to any of the
// community's conversations. The ban removes the membership in the same
// transaction and every later add refuses the account, and a claim needs the
// target to be a member, so no separate ban check is needed in the claim.
func TestBannedAccountDevicesCannotBeClaimed(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.addMember(t, ctx, alice, domain.RoleMember)
	if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ClaimDeviceKeyPackages(ctx, f.conv.ID, f.owner.Account.ID, f.owner.Device.ID, []string{alice.Device.ID}); err != nil {
		t.Fatalf("claim before the ban: %v", err)
	}
	if _, err := f.store.BanCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID); err != nil {
		t.Fatalf("ban: %v", err)
	}
	if _, err := f.store.ClaimDeviceKeyPackages(ctx, f.conv.ID, f.owner.Account.ID, f.owner.Device.ID, []string{alice.Device.ID}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("claim after the ban: %v", err)
	}
	if _, err := f.store.ManageConversationMember(ctx, f.conv.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("re-add after the ban: %v", err)
	}
}

// Migration 0095 on a database that already holds timeouts: a current
// member's timeout (still running or already over) is remembered, a member
// without one gets no row, and the remembered end comes back after a rejoin.
func TestTimeoutMigrationKeepsTimeoutsSetBeforeIt(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0094")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	running := registerTestMember(t, ctx, store, invite.Code, "running")
	over := registerTestMember(t, ctx, store, invite.Code, "over")
	none := registerTestMember(t, ctx, store, invite.Code, "nonetimeout")
	community, err := store.CreateCommunity(ctx, owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, who := range []AccountDevice{running, over, none} {
		if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, who.Account.ID, domain.RoleMember); err != nil {
			t.Fatal(err)
		}
	}
	// What SetMemberTimeout wrote before 0095.
	runningEnd := formatTime(time.Now().UTC().Add(time.Hour))
	overEnd := formatTime(time.Now().UTC().Add(-time.Hour))
	for who, end := range map[string]string{running.Account.ID: runningEnd, over.Account.ID: overEnd} {
		if _, err := store.db.ExecContext(ctx, `UPDATE memberships SET timeout_until = ? WHERE community_id = ? AND account_id = ?`, end, community.ID, who); err != nil {
			t.Fatal(err)
		}
	}

	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	remembered := map[string]string{}
	rows, err := store.db.QueryContext(ctx, `SELECT account_id, timeout_until FROM member_timeouts WHERE community_id = ?`, community.ID)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var account, end string
		if err := rows.Scan(&account, &end); err != nil {
			t.Fatal(err)
		}
		remembered[account] = end
	}
	if err := rows.Close(); err != nil {
		t.Fatal(err)
	}
	if len(remembered) != 2 || remembered[running.Account.ID] != runningEnd || remembered[over.Account.ID] != overEnd {
		t.Fatalf("remembered after 0095 = %v", remembered)
	}

	// Leaving and joining again keeps the running timeout.
	if _, err := store.RemoveCommunityMember(ctx, community.ID, running.Account.ID, running.Account.ID); err != nil {
		t.Fatalf("leave: %v", err)
	}
	if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, running.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("rejoin: %v", err)
	}
	var end sql.NullString
	if err := store.db.QueryRowContext(ctx, `SELECT timeout_until FROM memberships WHERE community_id = ? AND account_id = ?`, community.ID, running.Account.ID).Scan(&end); err != nil {
		t.Fatal(err)
	}
	if !end.Valid || end.String != runningEnd {
		t.Fatalf("timeout after rejoin = %v, want %s", end, runningEnd)
	}
}

// A deleted account's remembered timeouts go with its other rows: the account
// row stays as a deleted marker, so the foreign-key cascade never runs.
func TestDeletingAnAccountForgetsItsTimeouts(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	f.addMember(t, ctx, alice, domain.RoleMember)
	if _, err := f.store.SetMemberTimeout(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	count := func() int {
		t.Helper()
		var n int
		if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM member_timeouts WHERE account_id = ?`, alice.Account.ID).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if count() != 1 {
		t.Fatal("timeout not remembered")
	}
	if err := f.store.DeleteAccount(ctx, alice.Account.ID); err != nil {
		t.Fatal(err)
	}
	if n := count(); n != 0 {
		t.Fatalf("remembered timeouts after deleting the account: %d", n)
	}
}
