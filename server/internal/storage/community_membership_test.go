package storage

import (
	"context"
	"errors"
	"testing"

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
