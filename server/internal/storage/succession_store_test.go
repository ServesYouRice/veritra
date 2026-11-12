package storage

import (
	"context"
	"errors"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

// C4 server succession (docs/designs/C4-custom-roles.md, "Server
// succession"): the owner row moves only when the owner has been quiet for
// 37 days by the server's clock and a majority of admins asked for the same
// admin (or, with no admin, the longest-serving member claimed for itself).

type successionGroup struct {
	store  *Store
	conv   string
	owner  AccountDevice
	admins []AccountDevice
	member AccountDevice
	invite string
}

func newSuccessionGroup(t *testing.T, ctx context.Context, admins int) successionGroup {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 10, nil)
	if err != nil {
		t.Fatal(err)
	}
	g := successionGroup{store: store, owner: owner, invite: invite.Code}
	var ids []string
	for i := 0; i < admins; i++ {
		a := registerTestMember(t, ctx, store, invite.Code, "admin"+string(rune('a'+i)))
		g.admins = append(g.admins, a)
		ids = append(ids, a.Account.ID)
	}
	g.member = registerTestMember(t, ctx, store, invite.Code, "plainmember")
	ids = append(ids, g.member.Account.ID)
	conv, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: ids})
	if err != nil {
		t.Fatal(err)
	}
	g.conv = conv.ID
	for _, a := range g.admins {
		if _, err := store.ManageConversationMember(ctx, conv.ID, owner.Account.ID, a.Account.ID, domain.RoleAdmin); err != nil {
			t.Fatal(err)
		}
	}
	return g
}

func (g successionGroup) role(t *testing.T, ctx context.Context, account string) string {
	t.Helper()
	role, err := g.store.ConversationMemberRole(ctx, g.conv, account)
	if err != nil {
		t.Fatal(err)
	}
	return role
}

func (g successionGroup) setActive(t *testing.T, ctx context.Context, account string, ago time.Duration) {
	t.Helper()
	day := formatTime(domain.ActivityDay(time.Now().Add(-ago)))
	if _, err := g.store.db.ExecContext(ctx, `UPDATE memberships SET last_active_at = ? WHERE account_id = ?`, day, account); err != nil {
		t.Fatal(err)
	}
}

func (g successionGroup) ask(ctx context.Context, caller, candidate AccountDevice) (SuccessionStatus, error) {
	status, _, err := g.store.RequestConversationSuccession(ctx, g.conv, caller.Account.ID, candidate.Account.ID)
	return status, err
}

const daysAgo = 24 * time.Hour

func TestSuccessionNeedsAQuietOwnerAndAnAdminMajority(t *testing.T) {
	ctx := context.Background()
	g := newSuccessionGroup(t, ctx, 3)
	a, b, c := g.admins[0], g.admins[1], g.admins[2]

	// An active owner blocks it, whoever asks.
	for _, caller := range []AccountDevice{a, b, c} {
		if status, err := g.ask(ctx, caller, a); err != nil || status != SuccessionRecorded {
			t.Fatalf("ask while owner active: status=%q err=%v", status, err)
		}
	}
	if role := g.role(t, ctx, g.owner.Account.ID); role != domain.RoleOwner {
		t.Fatalf("owner role after asks = %q", role)
	}
	// Quiet for 36 days is not enough.
	g.setActive(t, ctx, g.owner.Account.ID, 36*daysAgo)
	if status, err := g.ask(ctx, a, a); err != nil || status != SuccessionRecorded {
		t.Fatalf("36 days: status=%q err=%v", status, err)
	}
	// 38 days, but the asks were made before the owner's last activity: they
	// do not count, and one fresh ask of three admins is no majority.
	g.setActive(t, ctx, g.owner.Account.ID, 38*daysAgo)
	stale := formatTime(time.Now().Add(-40 * daysAgo))
	if _, err := g.store.db.ExecContext(ctx, `UPDATE owner_succession_requests SET created_at = ?`, stale); err != nil {
		t.Fatal(err)
	}
	if status, err := g.ask(ctx, a, a); err != nil || status != SuccessionRecorded {
		t.Fatalf("stale asks: status=%q err=%v", status, err)
	}
	// A second admin asking for someone else does not combine with it.
	if status, err := g.ask(ctx, b, c); err != nil || status != SuccessionRecorded {
		t.Fatalf("split asks: status=%q err=%v", status, err)
	}
	// Two of three for the same admin after the quiet wait: it moves.
	if status, err := g.ask(ctx, b, a); err != nil || status != SuccessionMoved {
		t.Fatalf("majority: status=%q err=%v", status, err)
	}
	if role := g.role(t, ctx, a.Account.ID); role != domain.RoleOwner {
		t.Fatalf("new owner role = %q", role)
	}
	if role := g.role(t, ctx, g.owner.Account.ID); role != domain.RoleAdmin {
		t.Fatalf("old owner role = %q", role)
	}
	var asks int
	if err := g.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM owner_succession_requests`).Scan(&asks); err != nil || asks != 0 {
		t.Fatalf("asks after move = %d err=%v", asks, err)
	}
	// The new owner starts active: nobody can take it over at once.
	if status, err := g.ask(ctx, b, b); err != nil || status != SuccessionRecorded {
		t.Fatalf("after move: status=%q err=%v", status, err)
	}
	if status, err := g.ask(ctx, c, b); err != nil || status != SuccessionRecorded {
		t.Fatalf("after move second ask: status=%q err=%v", status, err)
	}
}

func TestSuccessionRefusesWrongCallersAndCandidates(t *testing.T) {
	ctx := context.Background()
	g := newSuccessionGroup(t, ctx, 2)
	a := g.admins[0]
	g.setActive(t, ctx, g.owner.Account.ID, 60*daysAgo)
	// A plain member does not ask while admins are present.
	if _, err := g.ask(ctx, g.member, a); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member ask err = %v", err)
	}
	// Nobody asks for a non-admin, or for the owner.
	if _, err := g.ask(ctx, a, g.member); !errors.Is(err, ErrForbidden) {
		t.Fatalf("non-admin candidate err = %v", err)
	}
	if _, err := g.ask(ctx, a, g.owner); !errors.Is(err, ErrForbidden) {
		t.Fatalf("owner candidate err = %v", err)
	}
	// An outsider is not a member.
	outsider := registerTestMember(t, ctx, g.store, g.invite, "outsider")
	if _, err := g.ask(ctx, outsider, a); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider err = %v", err)
	}
	// A DM has no succession.
	dm, err := g.store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: a.Account.ID, MemberAccountIDs: []string{g.member.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := g.store.RequestConversationSuccession(ctx, dm.ID, a.Account.ID, g.member.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("dm err = %v", err)
	}
	// One admin of two is not a majority.
	if status, err := g.ask(ctx, a, a); err != nil || status != SuccessionRecorded {
		t.Fatalf("one of two: status=%q err=%v", status, err)
	}
	if role := g.role(t, ctx, g.owner.Account.ID); role != domain.RoleOwner {
		t.Fatalf("owner role = %q", role)
	}
}

func TestSuccessionByTheOwnerIsATransfer(t *testing.T) {
	ctx := context.Background()
	g := newSuccessionGroup(t, ctx, 1)
	a := g.admins[0]
	// The owner's app saw it lose an election: no wait, no quorum.
	if _, err := g.ask(ctx, g.owner, g.member); !errors.Is(err, ErrForbidden) {
		t.Fatalf("owner to non-admin err = %v", err)
	}
	if status, err := g.ask(ctx, g.owner, a); err != nil || status != SuccessionMoved {
		t.Fatalf("owner transfer: status=%q err=%v", status, err)
	}
	if g.role(t, ctx, a.Account.ID) != domain.RoleOwner || g.role(t, ctx, g.owner.Account.ID) != domain.RoleAdmin {
		t.Fatal("transfer did not move the roles")
	}
}

func TestSuccessionWithNoAdminIsTheLongestServingMembersClaim(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	first := registerTestMember(t, ctx, store, invite.Code, "first")
	second := registerTestMember(t, ctx, store, invite.Code, "second")
	conv, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{first.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond)
	if _, err := store.ManageConversationMember(ctx, conv.ID, owner.Account.ID, second.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	ask := func(caller, candidate AccountDevice) (SuccessionStatus, error) {
		status, _, err := store.RequestConversationSuccession(ctx, conv.ID, caller.Account.ID, candidate.Account.ID)
		return status, err
	}
	if _, err := ask(second, second); !errors.Is(err, ErrForbidden) {
		t.Fatalf("younger member claim err = %v", err)
	}
	if _, err := ask(first, second); !errors.Is(err, ErrForbidden) {
		t.Fatalf("claim for another err = %v", err)
	}
	if status, err := ask(first, first); err != nil || status != SuccessionRecorded {
		t.Fatalf("claim while owner active: status=%q err=%v", status, err)
	}
	day := formatTime(domain.ActivityDay(time.Now().Add(-40 * daysAgo)))
	if _, err := store.db.ExecContext(ctx, `UPDATE memberships SET last_active_at = ? WHERE account_id = ?`, day, owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if status, err := ask(first, first); err != nil || status != SuccessionMoved {
		t.Fatalf("claim: status=%q err=%v", status, err)
	}
	if role, _ := store.ConversationMemberRole(ctx, conv.ID, first.Account.ID); role != domain.RoleOwner {
		t.Fatalf("claimant role = %q", role)
	}
	if role, _ := store.ConversationMemberRole(ctx, conv.ID, owner.Account.ID); role != domain.RoleAdmin {
		t.Fatalf("old owner role = %q", role)
	}
}

func TestSuccessionInACommunityFollowsTheOwnersActivityAndRows(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	quiet := func() {
		day := formatTime(domain.ActivityDay(time.Now().Add(-40 * daysAgo)))
		if _, err := f.store.db.ExecContext(ctx, `UPDATE memberships SET last_active_at = ? WHERE account_id = ?`, day, f.owner.Account.ID); err != nil {
			t.Fatal(err)
		}
	}
	quiet()
	// A post by the owner in the shared conversation is activity.
	if _, err := f.post(ctx, f.shared, f.owner, "owner-post", f.metadata(f.open.ID, f.community.LayoutGeneration)); err != nil {
		t.Fatal(err)
	}
	status, _, err := f.store.RequestCommunitySuccession(ctx, f.community.ID, f.member.Account.ID, f.member.Account.ID)
	if err != nil || status != SuccessionRecorded {
		t.Fatalf("owner posted today: status=%q err=%v", status, err)
	}
	// So is activity in a private channel only.
	quiet()
	if _, err := f.store.db.ExecContext(ctx, `UPDATE memberships SET last_active_at = ? WHERE account_id = ? AND conversation_id = ?`, formatTime(domain.ActivityDay(time.Now())), f.owner.Account.ID, f.privateConv); err != nil {
		t.Fatal(err)
	}
	status, _, err = f.store.RequestCommunitySuccession(ctx, f.community.ID, f.member.Account.ID, f.member.Account.ID)
	if err != nil || status != SuccessionRecorded {
		t.Fatalf("owner active in a private channel: status=%q err=%v", status, err)
	}
	quiet()
	status, _, err = f.store.RequestCommunitySuccession(ctx, f.community.ID, f.member.Account.ID, f.member.Account.ID)
	if err != nil || status != SuccessionMoved {
		t.Fatalf("quiet owner: status=%q err=%v", status, err)
	}
	if role, _ := f.store.CommunityMemberRole(ctx, f.community.ID, f.member.Account.ID); role != domain.RoleOwner {
		t.Fatalf("community role = %q", role)
	}
	if role, _ := f.store.CommunityMemberRole(ctx, f.community.ID, f.owner.Account.ID); role != domain.RoleAdmin {
		t.Fatalf("old owner community role = %q", role)
	}
	// The shared conversation and the old owner's private channel follow.
	if role, _ := f.store.ConversationMemberRole(ctx, f.shared, f.member.Account.ID); role != domain.RoleOwner {
		t.Fatalf("shared conversation role = %q", role)
	}
	if role, _ := f.store.ConversationMemberRole(ctx, f.privateConv, f.owner.Account.ID); role != domain.RoleAdmin {
		t.Fatalf("old owner private channel role = %q", role)
	}
}

func TestActivityIsRecordedOncePerDayAndTransfersClearAsks(t *testing.T) {
	ctx := context.Background()
	g := newSuccessionGroup(t, ctx, 2)
	a, b := g.admins[0], g.admins[1]
	g.setActive(t, ctx, g.owner.Account.ID, 60*daysAgo)
	if status, err := g.ask(ctx, a, a); err != nil || status != SuccessionRecorded {
		t.Fatalf("first ask: status=%q err=%v", status, err)
	}
	// The owner hands over to b in the ordinary way: a's ask lapses, and b
	// starts its tenure active.
	if _, err := g.store.ManageConversationMember(ctx, g.conv, g.owner.Account.ID, b.Account.ID, domain.RoleOwner); err != nil {
		t.Fatal(err)
	}
	var asks int
	if err := g.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM owner_succession_requests`).Scan(&asks); err != nil || asks != 0 {
		t.Fatalf("asks after transfer = %d err=%v", asks, err)
	}
	var last string
	if err := g.store.db.QueryRowContext(ctx, `SELECT last_active_at FROM memberships WHERE conversation_id = ? AND account_id = ?`, g.conv, b.Account.ID).Scan(&last); err != nil {
		t.Fatal(err)
	}
	if want := formatTime(domain.ActivityDay(time.Now())); last != want {
		t.Fatalf("new owner last_active_at = %q, want %q", last, want)
	}
	// A commit or a post keeps only the day.
	if _, err := g.store.db.ExecContext(ctx, `UPDATE memberships SET last_active_at = NULL WHERE conversation_id = ? AND account_id = ?`, g.conv, a.Account.ID); err != nil {
		t.Fatal(err)
	}
	tx, err := g.store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := touchMembershipActivityTx(ctx, tx, g.conv, a.Account.ID, time.Date(2030, 5, 6, 17, 4, 5, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := g.store.db.QueryRowContext(ctx, `SELECT last_active_at FROM memberships WHERE conversation_id = ? AND account_id = ?`, g.conv, a.Account.ID).Scan(&last); err != nil || last != "2030-05-06T00:00:00.000000000Z" {
		t.Fatalf("touched last_active_at = %q err=%v", last, err)
	}
}

func TestMigration0087StartsEveryMembershipActiveToday(t *testing.T) {
	ctx := context.Background()
	store, _ := openBareStoreAt(t)
	old, _ := migrationsUpTo(t, "0086")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	then := "2025-01-01T00:00:00.000000000Z"
	for _, statement := range []string{
		`INSERT INTO accounts(id, username, password_hash, role, status, created_at) VALUES('acct_a', 'alice', 'h', 'owner', 'active', '` + then + `')`,
		`INSERT INTO conversations(id, kind, title, created_by, created_at) VALUES('conv_old', 'group', NULL, 'acct_a', '` + then + `')`,
		`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('mbr_v', 'acct_a', 'conv_old', 'owner', '` + then + `')`,
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	var last string
	if err := store.db.QueryRowContext(ctx, `SELECT last_active_at FROM memberships WHERE id = 'mbr_v'`).Scan(&last); err != nil {
		t.Fatal(err)
	}
	if want := formatTime(domain.ActivityDay(time.Now())); last != want {
		t.Fatalf("backfilled last_active_at = %q, want %q", last, want)
	}
}
