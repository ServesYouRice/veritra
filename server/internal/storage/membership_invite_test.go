package storage

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
)

func testLocator(n int) string {
	return strings.Repeat(string("0123456789abcdef"[n%16]), 63) + string("0123456789abcdef"[(n/16)%16])
}

type inviteFixture struct {
	store  *Store
	owner  AccountDevice // instance owner and owner of the group and the community
	admin  AccountDevice // admin of both
	member AccountDevice // plain member of both
	people []AccountDevice
	group  domain.Conversation
	comm   domain.Community
	conv   domain.Conversation // channel conversation of comm
}

func newInviteFixture(t *testing.T, ctx context.Context, limits config.Limits) inviteFixture {
	t.Helper()
	store := newLimitedStore(t, limits)
	owner := createTestOwner(t, ctx, store)
	people := registerMembers(t, ctx, store, owner, "adminy", "membery", "alice", "bob", "carol")
	f := inviteFixture{store: store, owner: owner, admin: people[0], member: people[1], people: people[2:]}
	var err error
	f.group, err = store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{f.admin.Account.ID, f.member.Account.ID}})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}
	if _, err := store.ManageConversationMember(ctx, f.group.ID, owner.Account.ID, f.admin.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatalf("promote group admin: %v", err)
	}
	f.comm, err = store.CreateCommunity(ctx, "Club", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, f.conv, err = store.CreateChannelWithConversation(ctx, f.comm.ID, "general", "", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ManageCommunityMember(ctx, f.comm.ID, owner.Account.ID, f.admin.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ManageCommunityMember(ctx, f.comm.ID, owner.Account.ID, f.member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f inviteFixture) groupTarget() MembershipTarget {
	return MembershipTarget{Kind: domain.InviteTargetGroup, ID: f.group.ID}
}

func (f inviteFixture) communityTarget() MembershipTarget {
	return MembershipTarget{Kind: domain.InviteTargetCommunity, ID: f.comm.ID}
}

func (f inviteFixture) invite(t *testing.T, ctx context.Context, target MembershipTarget, by AccountDevice, locator string, maxUses int) domain.MembershipInvite {
	t.Helper()
	invite, err := f.store.CreateMembershipInvite(ctx, CreateMembershipInviteInput{Target: target, CreatedBy: by.Account.ID, Locator: locator, MaxUses: maxUses, ExpiresAt: time.Now().Add(time.Hour)})
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	return invite
}

func TestGroupInviteRequestApprovalJoinsOnce(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	invite := f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(1), 5)

	preview, err := f.store.PreviewMembershipInvite(ctx, alice.Account.ID, testLocator(1))
	if err != nil {
		t.Fatal(err)
	}
	if preview.TargetKind != domain.InviteTargetGroup || preview.InviterUsername != "adminy" || preview.AlreadyMember {
		t.Fatalf("preview = %+v", preview)
	}
	request, created, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(1))
	if err != nil || !created || request.Status != domain.JoinRequestPending {
		t.Fatalf("request = %+v created=%v err=%v", request, created, err)
	}
	// A request grants nothing.
	if member, _ := f.store.IsConversationMember(ctx, f.group.ID, alice.Account.ID); member {
		t.Fatal("a pending request made alice a member")
	}
	if _, err := f.store.ListConversationMembers(ctx, f.group.ID, alice.Account.ID); !errors.Is(err, ErrNotMember) {
		t.Fatalf("pending requester reads the member list: %v", err)
	}
	// Asking again returns the same request.
	again, created, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(1))
	if err != nil || created || again.ID != request.ID {
		t.Fatalf("second request = %+v created=%v err=%v", again, created, err)
	}
	listed, err := f.store.ListJoinRequests(ctx, f.groupTarget(), f.owner.Account.ID)
	if err != nil || len(listed) != 1 || listed[0].Username != "alice" || listed[0].AccountID != alice.Account.ID {
		t.Fatalf("listed = %+v err=%v", listed, err)
	}
	events := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'membership.updated' AND conversation_id = ?`, f.group.ID)
	decision, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, request.ID, true)
	if err != nil || !decision.Changed || decision.ConversationID != f.group.ID || decision.EventID == 0 {
		t.Fatalf("approve = %+v err=%v", decision, err)
	}
	if member, _ := f.store.IsConversationMember(ctx, f.group.ID, alice.Account.ID); !member {
		t.Fatal("approval did not make alice a member")
	}
	if role, _ := f.store.ConversationMemberRole(ctx, f.group.ID, alice.Account.ID); role != domain.RoleMember {
		t.Fatalf("role = %q", role)
	}
	if got := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'membership.updated' AND conversation_id = ?`, f.group.ID); got != events+1 {
		t.Fatalf("membership events %d -> %d, want one more", events, got)
	}
	if uses := testRowCount(t, ctx, f.store, `SELECT uses FROM membership_invites WHERE id = ?`, invite.ID); uses != 1 {
		t.Fatalf("uses = %d", uses)
	}
	// Repeating the approval is a no-op; the opposite decision is refused.
	repeat, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, request.ID, true)
	if err != nil || repeat.Changed {
		t.Fatalf("repeat approve = %+v err=%v", repeat, err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, request.ID, false); !errors.Is(err, ErrJoinRequestResolved) {
		t.Fatalf("reject after approve: %v", err)
	}
	if uses := testRowCount(t, ctx, f.store, `SELECT uses FROM membership_invites WHERE id = ?`, invite.ID); uses != 1 {
		t.Fatalf("uses after repeat = %d", uses)
	}
	// A member who asks again is told so.
	if _, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(1)); !errors.Is(err, ErrAlreadyMember) {
		t.Fatalf("member requests again: %v", err)
	}
	own, err := f.store.ListOwnJoinRequests(ctx, alice.Account.ID)
	if err != nil || len(own) != 1 || own[0].Status != domain.JoinRequestApproved || own[0].TargetID != f.group.ID {
		t.Fatalf("own = %+v err=%v", own, err)
	}
}

func TestCommunityInviteApprovalJoinsChannels(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	bob := f.people[1]
	f.invite(t, ctx, f.communityTarget(), f.owner, testLocator(2), 1)
	request, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(2))
	if err != nil {
		t.Fatal(err)
	}
	if role, err := f.store.CommunityMemberRole(ctx, f.comm.ID, bob.Account.ID); err == nil {
		t.Fatalf("pending requester has role %q", role)
	}
	decision, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, request.ID, true)
	if err != nil || len(decision.EventIDs) != 1 {
		t.Fatalf("approve = %+v err=%v", decision, err)
	}
	if role, err := f.store.CommunityMemberRole(ctx, f.comm.ID, bob.Account.ID); err != nil || role != domain.RoleMember {
		t.Fatalf("community role = %q err=%v", role, err)
	}
	if member, _ := f.store.IsConversationMember(ctx, f.conv.ID, bob.Account.ID); !member {
		t.Fatal("bob is not in the channel conversation")
	}
	members, err := f.store.ListCommunityMembers(ctx, f.comm.ID, bob.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, m := range members {
		if m.Username == "" {
			t.Fatalf("member %s has no username", m.AccountID)
		}
		names[m.Username] = true
	}
	if !names["bob"] || !names["adminy"] || !names["owner"] {
		t.Fatalf("usernames = %v", names)
	}
}

func TestInviteAndApprovalAuthorization(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	for _, target := range []MembershipTarget{f.groupTarget(), f.communityTarget()} {
		_, err := f.store.CreateMembershipInvite(ctx, CreateMembershipInviteInput{Target: target, CreatedBy: f.member.Account.ID, Locator: testLocator(3), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)})
		if !errors.Is(err, ErrForbidden) {
			t.Fatalf("%s: member creates invite: %v", target.Kind, err)
		}
		_, err = f.store.CreateMembershipInvite(ctx, CreateMembershipInviteInput{Target: target, CreatedBy: alice.Account.ID, Locator: testLocator(3), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)})
		if !errors.Is(err, ErrNotMember) {
			t.Fatalf("%s: outsider creates invite: %v", target.Kind, err)
		}
		if _, err := f.store.ListMembershipInvites(ctx, target, f.member.Account.ID); !errors.Is(err, ErrForbidden) {
			t.Fatalf("%s: member lists invites: %v", target.Kind, err)
		}
		if _, err := f.store.ListJoinRequests(ctx, target, alice.Account.ID); !errors.Is(err, ErrNotMember) {
			t.Fatalf("%s: outsider lists requests: %v", target.Kind, err)
		}
	}
	// Channel conversations and direct messages take no invitation.
	if _, err := f.store.CreateMembershipInvite(ctx, CreateMembershipInviteInput{Target: MembershipTarget{Kind: domain.InviteTargetGroup, ID: f.conv.ID}, CreatedBy: f.owner.Account.ID, Locator: testLocator(3), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)}); !errors.Is(err, ErrNotMember) {
		t.Fatalf("invite for a channel conversation: %v", err)
	}
	f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(4), 3)
	request, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(4))
	if err != nil {
		t.Fatal(err)
	}
	// Plain members, outsiders and the requester cannot decide, and learn nothing.
	for name, actor := range map[string]string{"member": f.member.Account.ID, "outsider": f.people[1].Account.ID, "requester": alice.Account.ID} {
		if _, err := f.store.DecideJoinRequest(ctx, actor, request.ID, true); !errors.Is(err, ErrNotFound) && !errors.Is(err, ErrForbidden) {
			t.Fatalf("%s decides: %v", name, err)
		}
	}
	if member, _ := f.store.IsConversationMember(ctx, f.group.ID, alice.Account.ID); member {
		t.Fatal("an unauthorized approval joined alice")
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, "jreq_missing", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown request: %v", err)
	}
	// Rejection records the decision and joins nobody; the same decision repeats.
	rejected, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, request.ID, false)
	if err != nil || !rejected.Changed || rejected.Request.Status != domain.JoinRequestRejected {
		t.Fatalf("reject = %+v err=%v", rejected, err)
	}
	if again, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, request.ID, false); err != nil || again.Changed {
		t.Fatalf("repeat reject = %+v err=%v", again, err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.admin.Account.ID, request.ID, true); !errors.Is(err, ErrJoinRequestResolved) {
		t.Fatalf("approve after reject: %v", err)
	}
	if uses := testRowCount(t, ctx, f.store, `SELECT COALESCE(SUM(uses), 0) FROM membership_invites`); uses != 0 {
		t.Fatalf("a rejection used the invite: %d", uses)
	}
	// After a rejection the account may ask again through the same link.
	if _, created, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(4)); err != nil || !created {
		t.Fatalf("ask again after reject: created=%v err=%v", created, err)
	}
}

func TestUnusableInvitesFailSafely(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob, carol := f.people[0], f.people[1], f.people[2]

	// Unknown and malformed locators look the same.
	for _, locator := range []string{testLocator(9), "short", strings.ToUpper(testLocator(9))} {
		if _, err := f.store.PreviewMembershipInvite(ctx, alice.Account.ID, locator); !errors.Is(err, ErrNotFound) {
			t.Fatalf("preview %q: %v", locator, err)
		}
		if _, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, locator); !errors.Is(err, ErrNotFound) {
			t.Fatalf("request %q: %v", locator, err)
		}
	}

	// Revoked: pending requests are cancelled and the link stops working.
	revoked := f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(10), 3)
	pending, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(10))
	if err != nil {
		t.Fatal(err)
	}
	if err := f.store.RevokeMembershipInvite(ctx, f.member.Account.ID, revoked.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("member revokes: %v", err)
	}
	if err := f.store.RevokeMembershipInvite(ctx, f.owner.Account.ID, revoked.ID); err != nil {
		t.Fatalf("owner revokes: %v", err)
	}
	if _, err := f.store.PreviewMembershipInvite(ctx, bob.Account.ID, testLocator(10)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("preview revoked: %v", err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(10)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("request revoked: %v", err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, pending.ID, true); !errors.Is(err, ErrJoinRequestResolved) {
		t.Fatalf("approve after revoke: %v", err)
	}
	if status := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests WHERE id = ? AND status = 'cancelled'`, pending.ID); status != 1 {
		t.Fatal("revoking did not cancel the pending request")
	}

	// Expired.
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(11), 3)
	if _, err := f.store.db.ExecContext(ctx, `UPDATE membership_invites SET expires_at = ? WHERE locator_hash = ?`, formatTime(time.Now().Add(-time.Minute)), hashLocator(testLocator(11))); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, carol.Account.ID, testLocator(11)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("request expired: %v", err)
	}

	// Pending request whose invite expires afterwards cannot be approved.
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(12), 3)
	late, _, err := f.store.RequestToJoin(ctx, carol.Account.ID, testLocator(12))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE membership_invites SET expires_at = ? WHERE locator_hash = ?`, formatTime(time.Now().Add(-time.Minute)), hashLocator(testLocator(12))); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, late.ID, true); !errors.Is(err, ErrMembershipInviteUnavailable) {
		t.Fatalf("approve after expiry: %v", err)
	}
	if listed, _ := f.store.ListJoinRequests(ctx, f.groupTarget(), f.owner.Account.ID); len(listed) != 0 {
		t.Fatalf("expired invite's request is listed: %+v", listed)
	}
	// Carol may ask through a fresh link; the dead request is replaced.
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(13), 3)
	if replaced, created, err := f.store.RequestToJoin(ctx, carol.Account.ID, testLocator(13)); err != nil || !created || replaced.ID == late.ID {
		t.Fatalf("replace dead request = %+v created=%v err=%v", replaced, created, err)
	}

	// The creator lost the admin role: their link no longer works.
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(14), 3)
	if _, err := f.store.db.ExecContext(ctx, `UPDATE memberships SET role = 'member' WHERE conversation_id = ? AND account_id = ?`, f.group.ID, f.admin.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(14)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("request with a demoted creator: %v", err)
	}
}

func TestInviteUseLimitAndDecisionRace(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob, carol := f.people[0], f.people[1], f.people[2]
	invite := f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(20), 1)
	first, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(20))
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(20))
	if err != nil {
		t.Fatal(err)
	}

	// Two concurrent approvals of the same request: one change, one use.
	var wg sync.WaitGroup
	results := make([]JoinDecision, 4)
	errs := make([]error, 4)
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i], errs[i] = f.store.DecideJoinRequest(ctx, f.owner.Account.ID, first.ID, true)
		}(i)
	}
	wg.Wait()
	changed := 0
	for i := range results {
		if errs[i] != nil {
			t.Fatalf("concurrent approve %d: %v", i, errs[i])
		}
		if results[i].Changed {
			changed++
		}
	}
	if changed != 1 {
		t.Fatalf("%d approvals changed state, want 1", changed)
	}
	if uses := testRowCount(t, ctx, f.store, `SELECT uses FROM membership_invites WHERE id = ?`, invite.ID); uses != 1 {
		t.Fatalf("uses = %d", uses)
	}
	// The link is used up: the second request was closed, cannot be approved, and nothing leaks.
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, second.ID, true); !errors.Is(err, ErrJoinRequestResolved) {
		t.Fatalf("approve beyond max uses: %v", err)
	}
	if member, _ := f.store.IsConversationMember(ctx, f.group.ID, bob.Account.ID); member {
		t.Fatal("bob joined past the use limit")
	}
	// The last use closed the other request on the link in the same transaction.
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests WHERE id = ? AND status = 'cancelled' AND decided_at IS NOT NULL`, second.ID); n != 1 {
		t.Fatal("the used up link left the other request pending")
	}
	if _, _, err := f.store.RequestToJoin(ctx, carol.Account.ID, testLocator(20)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("request on a used up link: %v", err)
	}
}

func TestApprovalRulesOfAddingMembersStillApply(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{ConversationMembers: 4})
	alice, bob := f.people[0], f.people[1]
	// The group holds three members (owner, admin, member); the limit is four.
	f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(30), 5)
	a, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(30))
	if err != nil {
		t.Fatal(err)
	}
	b, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(30))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, a.ID, true); err != nil {
		t.Fatalf("approve below the limit: %v", err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, b.ID, true); !errors.Is(err, ErrConversationMemberLimit) {
		t.Fatalf("approve at the member limit: %v", err)
	}
	if uses := testRowCount(t, ctx, f.store, `SELECT uses FROM membership_invites WHERE locator_hash = ?`, hashLocator(testLocator(30))); uses != 1 {
		t.Fatalf("a refused approval counted: uses = %d", uses)
	}
	if status := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests WHERE id = ? AND status = 'pending'`, b.ID); status != 1 {
		t.Fatal("a refused approval left the request decided")
	}
}

func TestBlockedPairAndDeletedAccounts(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(40), 5)
	// A block between requester and inviter looks like a dead link.
	if _, err := f.store.BlockAccount(ctx, alice.Account.ID, f.admin.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(40)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("blocked requester: %v", err)
	}
	if _, err := f.store.PreviewMembershipInvite(ctx, alice.Account.ID, testLocator(40)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("blocked preview: %v", err)
	}
	// A block against the approver refuses the approval and leaves the request pending.
	request, _, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(40))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.BlockAccount(ctx, bob.Account.ID, f.owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, request.ID, true); !errors.Is(err, ErrForbidden) {
		t.Fatalf("approve a blocked pair: %v", err)
	}
	if uses := testRowCount(t, ctx, f.store, `SELECT uses FROM membership_invites WHERE locator_hash = ?`, hashLocator(testLocator(40))); uses != 0 {
		t.Fatalf("uses = %d", uses)
	}
	// Deleting the creator ends their links and drops their own requests.
	if _, err := f.store.DeleteAccountData(ctx, f.admin.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.store.RequestToJoin(ctx, f.people[2].Account.ID, testLocator(40)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("link of a deleted creator: %v", err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests WHERE status = 'pending'`); n != 0 {
		t.Fatalf("pending requests after the creator's deletion: %d", n)
	}
	f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(41), 5)
	carol := f.people[2]
	if _, _, err := f.store.RequestToJoin(ctx, carol.Account.ID, testLocator(41)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.DeleteAccountData(ctx, carol.Account.ID); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests WHERE account_id = ?`, carol.Account.ID); n != 0 {
		t.Fatalf("requests of a deleted account: %d", n)
	}
}

func TestCancelAndBounds(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(50), 5)
	request, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(50))
	if err != nil {
		t.Fatal(err)
	}
	if err := f.store.CancelJoinRequest(ctx, bob.Account.ID, request.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("someone else cancels: %v", err)
	}
	if err := f.store.CancelJoinRequest(ctx, alice.Account.ID, request.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.store.CancelJoinRequest(ctx, alice.Account.ID, request.ID); err != nil {
		t.Fatalf("repeat cancel: %v", err)
	}
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, request.ID, true); !errors.Is(err, ErrJoinRequestResolved) {
		t.Fatalf("approve a cancelled request: %v", err)
	}
	// Input bounds.
	bad := []CreateMembershipInviteInput{
		{Target: f.groupTarget(), CreatedBy: f.owner.Account.ID, Locator: testLocator(51), MaxUses: 0, ExpiresAt: time.Now().Add(time.Hour)},
		{Target: f.groupTarget(), CreatedBy: f.owner.Account.ID, Locator: testLocator(51), MaxUses: 1001, ExpiresAt: time.Now().Add(time.Hour)},
		{Target: f.groupTarget(), CreatedBy: f.owner.Account.ID, Locator: testLocator(51), MaxUses: 1, ExpiresAt: time.Now().Add(-time.Hour)},
		{Target: f.groupTarget(), CreatedBy: f.owner.Account.ID, Locator: testLocator(51), MaxUses: 1, ExpiresAt: time.Now().Add(MaxMembershipInviteLifetime + time.Hour)},
		{Target: f.groupTarget(), CreatedBy: f.owner.Account.ID, Locator: "not-hex", MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)},
		{Target: MembershipTarget{Kind: "other", ID: f.group.ID}, CreatedBy: f.owner.Account.ID, Locator: testLocator(51), MaxUses: 1, ExpiresAt: time.Now().Add(time.Hour)},
	}
	for i, input := range bad {
		if _, err := f.store.CreateMembershipInvite(ctx, input); !errors.Is(err, ErrInvalidInput) {
			t.Fatalf("bad input %d: %v", i, err)
		}
	}
	// A locator is stored hashed; nothing holds it.
	var stored string
	if err := f.store.db.QueryRowContext(ctx, `SELECT locator_hash FROM membership_invites LIMIT 1`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored == testLocator(50) || strings.Contains(stored, testLocator(50)) {
		t.Fatal("the locator is stored in the clear")
	}
	// Pending requests per account are bounded.
	for i := 0; i < maxPendingRequestsPerAccount+1; i++ {
		other, err := f.store.CreateCommunity(ctx, "c", f.owner.Account.ID)
		if err != nil {
			t.Fatal(err)
		}
		f.invite(t, ctx, MembershipTarget{Kind: domain.InviteTargetCommunity, ID: other.ID}, f.owner, testLocator(100+i), 1)
		_, _, err = f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(100+i))
		if i < maxPendingRequestsPerAccount && err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
		if i == maxPendingRequestsPerAccount && !errors.Is(err, ErrJoinRequestLimit) {
			t.Fatalf("request beyond the account bound: %v", err)
		}
	}
}

func TestRemoveCommunityMember(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	if _, err := f.store.ManageCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	// A plain member cannot remove another member; outsiders are refused; unknown targets are not found.
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.member.Account.ID, alice.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member removes member: %v", err)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.people[1].Account.ID, alice.Account.ID); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider removes: %v", err)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, f.people[1].Account.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("remove a non-member: %v", err)
	}
	// An admin cannot remove the owner or another admin of equal rank.
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, f.owner.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("admin removes owner: %v", err)
	}
	// The last owner cannot leave.
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, f.owner.Account.ID); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("last owner leaves: %v", err)
	}
	events := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events`)
	removal, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID)
	if err != nil || len(removal.Channels) != 1 || removal.Channels[0].ConversationID != f.conv.ID {
		t.Fatalf("admin removes member: %+v err=%v", removal, err)
	}
	if _, err := f.store.CommunityMemberRole(ctx, f.comm.ID, alice.Account.ID); err == nil {
		t.Fatal("alice is still a community member")
	}
	if member, _ := f.store.IsConversationMember(ctx, f.conv.ID, alice.Account.ID); member {
		t.Fatal("alice is still in the channel conversation")
	}
	if got := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events`); got != events+2 {
		t.Fatalf("events %d -> %d, want one for the rest and one for alice", events, got)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'membership.removed' AND account_id = ?`, alice.Account.ID); n != 1 {
		t.Fatalf("removed-member events = %d", n)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.admin.Account.ID, alice.Account.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("remove twice: %v", err)
	}
	// Leaving: a member leaves; after a second owner exists, the first may leave.
	if removal, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.member.Account.ID, f.member.Account.ID); err != nil || len(removal.Channels) != 1 {
		t.Fatalf("member leaves: %+v err=%v", removal, err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'membership.left' AND account_id = ?`, f.member.Account.ID); n != 1 {
		t.Fatalf("leave events = %d", n)
	}
	if _, err := f.store.db.ExecContext(ctx, `UPDATE memberships SET role = 'owner' WHERE community_id = ? AND account_id = ?`, f.comm.ID, f.admin.Account.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, f.owner.Account.ID); err != nil {
		t.Fatalf("owner leaves with another owner present: %v", err)
	}
	// A community without channels still notifies the removed account.
	empty, err := f.store.CreateCommunity(ctx, "Empty", f.owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ManageCommunityMember(ctx, empty.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.RemoveCommunityMember(ctx, empty.ID, f.owner.Account.ID, alice.Account.ID); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM sync_events WHERE account_id = ? AND payload_json LIKE ?`, alice.Account.ID, `%`+empty.ID+`%`); n != 1 {
		t.Fatalf("events for a channel-less removal = %d", n)
	}
}

// The app derives the locator from the link secret (mobile
// test/membership_invite_link_test.dart pins the same locator); the store
// keeps only this hash of it. The vector ties the two sides together.
func TestHashLocatorVector(t *testing.T) {
	const locator = "4437d01b5bc6825b22a3de68051fee45b5809368049546cf0a8169cdb2ddcc52"
	const want = "281c1a375133b420d423b226a9281ac28614e9d252d85ea61972c5c17567981a"
	if got := hashLocator(locator); got != want {
		t.Fatalf("hashLocator = %s, want %s", got, want)
	}
	if !validLocator(locator) || validLocator(strings.ToUpper(locator)) || validLocator(locator[1:]) {
		t.Fatal("validLocator accepts the wrong shapes")
	}
}

// ownStatus is the status the requester sees for the request.
func ownStatus(t *testing.T, ctx context.Context, f inviteFixture, accountID, requestID string) string {
	t.Helper()
	own, err := f.store.ListOwnJoinRequests(ctx, accountID)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range own {
		if r.ID == requestID {
			return r.Status
		}
	}
	t.Fatalf("request %s not listed for its requester", requestID)
	return ""
}

func TestUsedUpInviteCancelsOtherPendingRequests(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(60), 1)
	a, _, _ := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(60))
	b, _, _ := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(60))
	if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, a.ID, true); err != nil {
		t.Fatal(err)
	}
	if got := ownStatus(t, ctx, f, bob.Account.ID, b.ID); got != domain.JoinRequestCancelled {
		t.Fatalf("bob sees %q after the link was used up", got)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests WHERE account_id = ? AND status = 'pending'`, bob.Account.ID); n != 0 {
		t.Fatalf("%d pending rows stay for bob", n)
	}
	// Bob can ask again through a new link at once: nothing dead counts.
	f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(61), 1)
	if _, created, err := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(61)); err != nil || !created {
		t.Fatalf("new request: created=%v err=%v", created, err)
	}
}

func TestDeadRequestsDoNotCountAgainstCapsOrList(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice := f.people[0]
	invite := f.invite(t, ctx, f.groupTarget(), f.admin, testLocator(62), 5)
	req, _, err := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(62))
	if err != nil {
		t.Fatal(err)
	}
	capped := func() (int, int) {
		community, conversation := f.groupTarget().columns()
		own := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests r JOIN membership_invites i ON i.id = r.invite_id WHERE r.account_id = ? AND r.status = 'pending' AND `+usableInviteSQL, alice.Account.ID, nowString())
		target := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM membership_join_requests r JOIN membership_invites i ON i.id = r.invite_id WHERE r.community_id IS ? AND r.conversation_id IS ? AND r.status = 'pending' AND `+usableInviteSQL, community, conversation, nowString())
		return own, target
	}
	if own, target := capped(); own != 1 || target != 1 {
		t.Fatalf("live request counted own=%d target=%d", own, target)
	}
	listed := func() int {
		l, err := f.store.ListJoinRequests(ctx, f.groupTarget(), f.owner.Account.ID)
		if err != nil {
			t.Fatal(err)
		}
		return len(l)
	}
	if listed() != 1 {
		t.Fatal("live request not listed")
	}

	t.Run("expired", func(t *testing.T) {
		if _, err := f.store.db.ExecContext(ctx, `UPDATE membership_invites SET expires_at = ? WHERE id = ?`, formatTime(time.Now().Add(-time.Minute)), invite.ID); err != nil {
			t.Fatal(err)
		}
		if own, target := capped(); own != 0 || target != 0 || listed() != 0 {
			t.Fatalf("expired: own=%d target=%d listed=%d", own, target, listed())
		}
		if got := ownStatus(t, ctx, f, alice.Account.ID, req.ID); got != domain.JoinRequestCancelled {
			t.Fatalf("requester sees %q for an expired link", got)
		}
		if _, err := f.store.db.ExecContext(ctx, `UPDATE membership_invites SET expires_at = ? WHERE id = ?`, formatTime(time.Now().Add(time.Hour)), invite.ID); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("creator demoted", func(t *testing.T) {
		if _, err := f.store.ManageConversationMember(ctx, f.group.ID, f.owner.Account.ID, f.admin.Account.ID, domain.RoleMember); err != nil {
			t.Fatal(err)
		}
		if own, target := capped(); own != 0 || target != 0 || listed() != 0 {
			t.Fatalf("demoted creator: own=%d target=%d listed=%d", own, target, listed())
		}
		if got := ownStatus(t, ctx, f, alice.Account.ID, req.ID); got != domain.JoinRequestCancelled {
			t.Fatalf("requester sees %q after the creator was demoted", got)
		}
		if _, err := f.store.DecideJoinRequest(ctx, f.owner.Account.ID, req.ID, true); !errors.Is(err, ErrMembershipInviteUnavailable) {
			t.Fatalf("approve after demotion: %v", err)
		}
		// Promoting the creator again makes the request live again.
		if _, err := f.store.ManageConversationMember(ctx, f.group.ID, f.owner.Account.ID, f.admin.Account.ID, domain.RoleAdmin); err != nil {
			t.Fatal(err)
		}
		if listed() != 1 {
			t.Fatal("request not listed once the creator is admin again")
		}
	})

	t.Run("creator deleted", func(t *testing.T) {
		if err := f.store.DeleteAccount(ctx, f.admin.Account.ID); err != nil {
			t.Fatal(err)
		}
		if own, target := capped(); own != 0 || target != 0 || listed() != 0 {
			t.Fatalf("deleted creator: own=%d target=%d listed=%d", own, target, listed())
		}
	})
}

func TestHandAddedRequesterRequestsAreCancelled(t *testing.T) {
	ctx := context.Background()
	f := newInviteFixture(t, ctx, config.Limits{})
	alice, bob := f.people[0], f.people[1]
	f.invite(t, ctx, f.groupTarget(), f.owner, testLocator(63), 5)
	f.invite(t, ctx, f.communityTarget(), f.owner, testLocator(64), 5)
	ga, _, _ := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(63))
	ca, _, _ := f.store.RequestToJoin(ctx, alice.Account.ID, testLocator(64))
	gb, _, _ := f.store.RequestToJoin(ctx, bob.Account.ID, testLocator(63))

	if _, err := f.store.ManageConversationMember(ctx, f.group.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ManageCommunityMember(ctx, f.comm.ID, f.owner.Account.ID, alice.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	for _, target := range []MembershipTarget{f.groupTarget(), f.communityTarget()} {
		listed, err := f.store.ListJoinRequests(ctx, target, f.owner.Account.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range listed {
			if r.AccountID == alice.Account.ID {
				t.Fatalf("hand-added alice still listed for %s", target.Kind)
			}
		}
	}
	for _, id := range []string{ga.ID, ca.ID} {
		if got := ownStatus(t, ctx, f, alice.Account.ID, id); got != domain.JoinRequestCancelled {
			t.Fatalf("alice's request %s is %q", id, got)
		}
	}
	// Bob, not added, keeps his request; cancelling is per target and account.
	if got := ownStatus(t, ctx, f, bob.Account.ID, gb.ID); got != domain.JoinRequestPending {
		t.Fatalf("bob's request is %q", got)
	}
}
