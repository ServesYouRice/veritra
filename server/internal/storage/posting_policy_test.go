package storage

import (
	"context"
	"errors"
	"testing"

	"private-messenger/server/internal/domain"
)

func postAs(ctx context.Context, store *Store, conversationID string, who AccountDevice, key string) error {
	_, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID: conversationID, SenderAccountID: who.Account.ID, SenderDeviceID: who.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo",
	})
	return err
}

func TestAdminsOnlyGroupRefusesMemberPosts(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "member")
	group, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.AddConversationMember(ctx, group.ID, member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := postAs(ctx, store, group.ID, member, "a1"); err != nil {
		t.Fatalf("open group: member post refused: %v", err)
	}
	if _, _, err := store.SetConversationPostingPolicy(ctx, group.ID, member.Account.ID, PostingPolicyAdmins); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member changed the policy: %v", err)
	}
	if _, _, err := store.SetConversationPostingPolicy(ctx, group.ID, owner.Account.ID, "nobody"); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("bad policy: %v", err)
	}
	conversation, eventID, err := store.SetConversationPostingPolicy(ctx, group.ID, owner.Account.ID, PostingPolicyAdmins)
	if err != nil || eventID == 0 || !conversation.PostingRestricted {
		t.Fatalf("set admins: %+v event=%d err=%v", conversation, eventID, err)
	}
	if err := postAs(ctx, store, group.ID, member, "a2"); !errors.Is(err, ErrPostingRestricted) {
		t.Fatalf("member post in admins-only group: %v", err)
	}
	if err := postAs(ctx, store, group.ID, owner, "o1"); err != nil {
		t.Fatalf("owner post refused: %v", err)
	}
	// A retry of a post stored before the switch still answers.
	if err := postAs(ctx, store, group.ID, member, "a1"); err != nil {
		t.Fatalf("idempotent replay refused: %v", err)
	}
	listed, err := store.ListConversations(ctx, member.Account.ID)
	if err != nil || len(listed) != 1 || !listed[0].PostingRestricted {
		t.Fatalf("list: %+v err=%v", listed, err)
	}
	if _, _, err := store.SetConversationPostingPolicy(ctx, group.ID, owner.Account.ID, PostingPolicyEveryone); err != nil {
		t.Fatal(err)
	}
	if err := postAs(ctx, store, group.ID, member, "a3"); err != nil {
		t.Fatalf("lifted: %v", err)
	}
	dm, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{member.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.SetConversationPostingPolicy(ctx, dm.ID, owner.Account.ID, PostingPolicyAdmins); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("dm policy: %v", err)
	}
}

func TestAnnouncementChannelRefusesMemberPosts(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "member")
	community, err := store.CreateCommunity(ctx, "c", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	_, news, err := store.CreateChannelWithConversation(ctx, community.ID, "news", "announcement", owner.Account.ID)
	if err != nil || !news.PostingRestricted {
		t.Fatalf("announcement: %+v %v", news, err)
	}
	_, chat, err := store.CreateChannelWithConversation(ctx, community.ID, "chat", "private", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := postAs(ctx, store, news.ID, member, "n1"); !errors.Is(err, ErrPostingRestricted) {
		t.Fatalf("member in announcement: %v", err)
	}
	if err := postAs(ctx, store, news.ID, owner, "n2"); err != nil {
		t.Fatalf("owner in announcement: %v", err)
	}
	if err := postAs(ctx, store, chat.ID, member, "c1"); err != nil {
		t.Fatalf("member in chat channel: %v", err)
	}
	got, err := store.ConversationByID(ctx, news.ID)
	if err != nil || !got.PostingRestricted {
		t.Fatalf("by id: %+v %v", got, err)
	}
}
