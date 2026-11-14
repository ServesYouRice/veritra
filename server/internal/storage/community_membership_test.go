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
	community, err := store.CreateCommunity(ctx, owner.Account.ID)
	if err != nil {
		t.Fatalf("create community: %v", err)
	}
	channel, conversation, err := store.CreateChannelWithConversation(ctx, community.ID, "", owner.Account.ID)
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

// fullMemberChannel builds a legacy community of owner, busy and free under a
// limit of three conversations, puts busy at the limit (two groups and a first
// channel), and makes a second channel, which leaves busy out (D134). It
// returns busy's first group, so a test can free a slot.
func fullMemberChannel(t *testing.T, ctx context.Context) (store *Store, owner, busy, free AccountDevice, communityID string, channel domain.Conversation, busyGroup string) {
	t.Helper()
	store = newLimitedStore(t, config.Limits{ConversationsPerAccount: 3})
	owner = createTestOwner(t, ctx, store)
	members := registerMembers(t, ctx, store, owner, "busy", "free")
	busy, free = members[0], members[1]
	community, err := store.CreateCommunity(ctx, owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, member := range members {
		if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, member.Account.ID, domain.RoleMember); err != nil {
			t.Fatalf("add %s: %v", member.Account.Username, err)
		}
	}
	for i := 0; i < 2; i++ {
		group, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: busy.Account.ID})
		if err != nil {
			t.Fatalf("busy group %d: %v", i, err)
		}
		if i == 0 {
			busyGroup = group.ID
		}
	}
	if _, _, skipped, err := store.CreateChannelSkippingFullMembers(ctx, community.ID, "", owner.Account.ID); err != nil || skipped != 0 {
		t.Fatalf("channel below every member's limit: skipped=%d err=%v", skipped, err)
	}
	if got := rejections(store, admission.Conversations); got != 0 {
		t.Fatalf("conversation-limit rejections before the full channel = %d, want 0", got)
	}
	_, channel, skipped, err := store.CreateChannelSkippingFullMembers(ctx, community.ID, "", owner.Account.ID)
	if err != nil {
		t.Fatalf("channel with a member at the conversation limit: %v (D134: it is made without that member)", err)
	}
	if skipped != 1 {
		t.Fatalf("skipped = %d, want 1", skipped)
	}
	return store, owner, busy, free, community.ID, channel, busyGroup
}

func channelMember(t *testing.T, ctx context.Context, store *Store, conversationID, accountID string) bool {
	t.Helper()
	return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, accountID) == 1
}

func conversationCount(t *testing.T, ctx context.Context, store *Store, accountID string) int {
	t.Helper()
	return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM memberships WHERE account_id = ? AND conversation_id IS NOT NULL`, accountID)
}

// D134: a member at the conversation limit is left out of a new legacy
// channel instead of refusing it; nothing about the channel names it, the MLS
// group never gets its devices, and it joins later through the ordinary add
// once it has room.
func TestCreateChannelSkipsMemberAtConversationLimit(t *testing.T) {
	ctx := context.Background()
	store, owner, busy, free, _, channel, busyGroup := fullMemberChannel(t, ctx)

	if !channelMember(t, ctx, store, channel.ID, owner.Account.ID) || !channelMember(t, ctx, store, channel.ID, free.Account.ID) {
		t.Fatal("members with room were not added to the channel")
	}
	if channelMember(t, ctx, store, channel.ID, busy.Account.ID) {
		t.Fatal("member at the limit was added to the channel")
	}
	if got := conversationCount(t, ctx, store, busy.Account.ID); got != 3 {
		t.Fatalf("busy conversations = %d, want 3 (the limit)", got)
	}
	events := func(accountID string) int {
		return testRowCount(t, ctx, store, `SELECT COUNT(*) FROM sync_events WHERE conversation_id = ? AND account_id = ?`, channel.ID, accountID)
	}
	if events(busy.Account.ID) != 0 || events(free.Account.ID) != 1 {
		t.Fatalf("membership events busy=%d free=%d, want 0 and 1", events(busy.Account.ID), events(free.Account.ID))
	}
	if got := rejections(store, admission.Conversations); got != 1 {
		t.Fatalf("conversation-limit rejections = %d, want 1", got)
	}

	// The creator's device seeds the group from the server roster: busy has
	// nothing to claim, and once the group exists nothing is pending for it.
	packages, err := store.ClaimConversationKeyPackages(ctx, channel.ID, owner.Account.ID, owner.Device.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, pkg := range packages {
		if pkg.AccountID == busy.Account.ID {
			t.Fatalf("claimed a key package of the left-out member: %#v", pkg)
		}
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: channel.ID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: free.Account.ID, DeviceID: free.Device.ID}},
	}); err != nil {
		t.Fatal(err)
	}
	pendingAdds := func() []MLSDeviceRef {
		t.Helper()
		changes, err := store.ListMLSPendingChanges(ctx, owner.Account.ID, owner.Device.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, change := range changes {
			if change.ConversationID == channel.ID {
				return change.Add
			}
		}
		return nil
	}
	if adds := pendingAdds(); len(adds) != 0 {
		t.Fatalf("pending adds after genesis = %#v, want none", adds)
	}

	// Still at the limit: the ordinary channel add refuses it.
	if _, err := store.ManageConversationMember(ctx, channel.ID, owner.Account.ID, busy.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("adding a member still at the limit: err = %v, want %v", err, ErrForbidden)
	}
	// With a slot free, the same add succeeds and becomes a pending MLS add.
	if _, err := store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, busyGroup, busy.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ManageConversationMember(ctx, channel.ID, owner.Account.ID, busy.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("adding the left-out member once it has room: %v", err)
	}
	adds := pendingAdds()
	if len(adds) != 1 || adds[0].AccountID != busy.Account.ID || adds[0].DeviceID != busy.Device.ID {
		t.Fatalf("pending adds after the late join = %#v, want busy's device", adds)
	}
}

// A community role change writes the role into every legacy channel, adding a
// row where one is missing. For a member left out at the limit (D134) it adds
// one only when the member has room, so the limit still holds.
func TestCommunityRoleChangeKeepsTheConversationLimitForALeftOutMember(t *testing.T) {
	ctx := context.Background()
	store, owner, busy, _, communityID, channel, busyGroup := fullMemberChannel(t, ctx)

	if _, err := store.ManageCommunityMember(ctx, communityID, owner.Account.ID, busy.Account.ID, domain.RoleModerator); err != nil {
		t.Fatalf("role change of a member at the limit: %v", err)
	}
	if channelMember(t, ctx, store, channel.ID, busy.Account.ID) {
		t.Fatal("role change added a member at the limit to the channel it was left out of")
	}
	if got := conversationCount(t, ctx, store, busy.Account.ID); got != 3 {
		t.Fatalf("busy conversations after the role change = %d, want 3", got)
	}
	if got := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM memberships m JOIN conversations c ON c.id = m.conversation_id
		WHERE c.community_id = ? AND m.account_id = ? AND m.role = ?`, communityID, busy.Account.ID, domain.RoleModerator); got != 1 {
		t.Fatalf("channels where busy is a moderator = %d, want 1 (the one it holds)", got)
	}

	if _, err := store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, busyGroup, busy.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ManageCommunityMember(ctx, communityID, owner.Account.ID, busy.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("role change with room: %v", err)
	}
	if !channelMember(t, ctx, store, channel.ID, busy.Account.ID) {
		t.Fatal("role change with room did not add the left-out member to the channel")
	}
	if got := conversationCount(t, ctx, store, busy.Account.ID); got != 3 {
		t.Fatalf("busy conversations after the join = %d, want 3", got)
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
