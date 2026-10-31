package storage

import (
	"context"
	"errors"
	"testing"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

type communityFixture struct {
	store        *Store
	owner        AccountDevice
	insider      AccountDevice
	outsider     AccountDevice
	community    domain.Community
	channel      domain.Channel
	conversation domain.Conversation
}

// newCommunityFixture builds a community with a channel conversation. The
// owner and insider are community members; the outsider is registered but
// belongs to no community.
func newCommunityFixture(t *testing.T, ctx context.Context) communityFixture {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 4, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	insider := registerTestMember(t, ctx, store, invite.Code, "insider")
	outsider := registerTestMember(t, ctx, store, invite.Code, "outsider")
	community, err := store.CreateCommunity(ctx, "Club", owner.Account.ID)
	if err != nil {
		t.Fatalf("create community: %v", err)
	}
	channel, conversation, err := store.CreateChannelWithConversation(ctx, community.ID, "general", "", owner.Account.ID)
	if err != nil {
		t.Fatalf("create channel: %v", err)
	}
	if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, insider.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add insider: %v", err)
	}
	return communityFixture{store: store, owner: owner, insider: insider, outsider: outsider, community: community, channel: channel, conversation: conversation}
}

func TestManageConversationMemberRefusesOutsiderInCommunityChannel(t *testing.T) {
	ctx := context.Background()
	f := newCommunityFixture(t, ctx)
	var eventsBefore int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events`).Scan(&eventsBefore); err != nil {
		t.Fatal(err)
	}
	_, err := f.store.ManageConversationMember(ctx, f.conversation.ID, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember)
	if !errors.Is(err, ErrForbidden) {
		t.Fatalf("adding an outsider to a community channel: err = %v, want %v", err, ErrForbidden)
	}
	if member, err := f.store.IsConversationMember(ctx, f.conversation.ID, f.outsider.Account.ID); err != nil || member {
		t.Fatalf("outsider membership = %v, err = %v, want none", member, err)
	}
	var eventsAfter int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events`).Scan(&eventsAfter); err != nil {
		t.Fatal(err)
	}
	if eventsAfter != eventsBefore {
		t.Fatalf("sync events %d -> %d, want no event for a refused add", eventsBefore, eventsAfter)
	}
	// A community member who left the channel can be added back, and an
	// existing member's role can still be changed.
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, f.conversation.ID, f.insider.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ManageConversationMember(ctx, f.conversation.ID, f.owner.Account.ID, f.insider.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("re-adding a community member to its channel: %v", err)
	}
	if _, err := f.store.ManageConversationMember(ctx, f.conversation.ID, f.owner.Account.ID, f.insider.Account.ID, domain.RoleModerator); err != nil {
		t.Fatalf("role change of an existing channel member: %v", err)
	}
}

func TestCreateChannelWithConversationRespectsMemberConversationLimit(t *testing.T) {
	ctx := context.Background()
	store := newLimitedStore(t, config.Limits{ConversationsPerAccount: 3})
	owner := createTestOwner(t, ctx, store)
	members := registerMembers(t, ctx, store, owner, "busy", "free")
	busy := members[0]
	community, err := store.CreateCommunity(ctx, "Club", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, member := range members {
		if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, member.Account.ID, domain.RoleMember); err != nil {
			t.Fatalf("add %s: %v", member.Account.Username, err)
		}
	}
	// busy sits at the limit after two groups plus the channel it will hold.
	for i := 0; i < 2; i++ {
		if _, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: busy.Account.ID}); err != nil {
			t.Fatalf("busy group %d: %v", i, err)
		}
	}
	if _, _, err := store.CreateChannelWithConversation(ctx, community.ID, "first", "", owner.Account.ID); err != nil {
		t.Fatalf("channel below every member's limit: %v", err)
	}
	snapshot := func() [4]int {
		var counts [4]int
		for i, query := range []string{
			`SELECT COUNT(*) FROM channels`,
			`SELECT COUNT(*) FROM conversations`,
			`SELECT COUNT(*) FROM memberships`,
			`SELECT COUNT(*) FROM sync_events`,
		} {
			counts[i] = testRowCount(t, ctx, store, query)
		}
		return counts
	}
	before := snapshot()
	_, _, err = store.CreateChannelWithConversation(ctx, community.ID, "second", "", owner.Account.ID)
	if !errors.Is(err, ErrForbidden) {
		t.Fatalf("channel that would exceed a member's conversation limit: err = %v, want %v", err, ErrForbidden)
	}
	if after := snapshot(); after != before {
		t.Fatalf("refused channel changed rows: channels/conversations/memberships/sync_events %v -> %v", before, after)
	}
	if got := rejections(store, admission.Conversations); got != 1 {
		t.Fatalf("conversation-limit rejections = %d, want 1", got)
	}
}

func TestManageCommunityMemberRejectsBlockedAccounts(t *testing.T) {
	for _, tc := range []struct {
		name string
		// blocker and blocked pick who blocks whom among the owner (the actor)
		// and the outsider (the target).
		ownerBlocks bool
	}{
		{"actor blocks target", true},
		{"target blocks actor", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			f := newCommunityFixture(t, ctx)
			var err error
			if tc.ownerBlocks {
				_, err = f.store.BlockAccount(ctx, f.owner.Account.ID, f.outsider.Account.ID)
			} else {
				_, err = f.store.BlockAccount(ctx, f.outsider.Account.ID, f.owner.Account.ID)
			}
			if err != nil {
				t.Fatalf("block: %v", err)
			}
			rowCounts := func() [2]int {
				return [2]int{
					testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM memberships`),
					testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'membership.updated'`),
				}
			}
			before := rowCounts()
			if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
				t.Fatalf("add across a block: err = %v, want %v", err, ErrForbidden)
			}
			if after := rowCounts(); after != before {
				t.Fatalf("memberships/membership events %v -> %v, want nothing written", before, after)
			}
			// A role change of an existing member is refused the same way.
			if tc.ownerBlocks {
				_, err = f.store.BlockAccount(ctx, f.owner.Account.ID, f.insider.Account.ID)
			} else {
				_, err = f.store.BlockAccount(ctx, f.insider.Account.ID, f.owner.Account.ID)
			}
			if err != nil {
				t.Fatalf("block insider: %v", err)
			}
			if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.insider.Account.ID, domain.RoleModerator); !errors.Is(err, ErrForbidden) {
				t.Fatalf("role change across a block: err = %v, want %v", err, ErrForbidden)
			}
		})
	}
}

func TestManageCommunityMemberAddsUnblockedAccounts(t *testing.T) {
	ctx := context.Background()
	f := newCommunityFixture(t, ctx)
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add unblocked account: %v", err)
	}
	if member, err := f.store.IsConversationMember(ctx, f.conversation.ID, f.outsider.Account.ID); err != nil || !member {
		t.Fatalf("new community member in channel = %v, err = %v, want member", member, err)
	}
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleModerator); err != nil {
		t.Fatalf("unblocked role change: %v", err)
	}
}

func TestManageConversationMemberStillAddsToGroupConversations(t *testing.T) {
	ctx := context.Background()
	f := newCommunityFixture(t, ctx)
	group, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ManageConversationMember(ctx, group.ID, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("adding a non-community account to a group: %v", err)
	}
}
