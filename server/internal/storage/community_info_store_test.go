package storage

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"private-messenger/server/internal/domain"
)

// C3 (docs/designs/C3-private-channels-and-info.md): community, category and
// channel records reuse W11's table with their own read and write rules.

func infoBlob() []byte { return append([]byte("VPE1"), make([]byte, 4096+24)...) }

var infoKey = strings.Repeat("b", 32)

func newCategoryID(t *testing.T) string {
	t.Helper()
	id, err := domain.NewID(CategoryIDPrefix)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func (f layoutFixture) putInfo(ctx context.Context, kind, subject, community string, who AccountDevice, expected int64) (int64, []ProfileNotice, error) {
	return f.store.PutProfile(ctx, ProfileWrite{
		Kind: kind, SubjectID: subject, CommunityID: community, WriterAccountID: who.Account.ID,
		KeyID: infoKey, Ciphertext: infoBlob(), ExpectedVersion: expected,
	})
}

func (f layoutFixture) readable(ctx context.Context, kind, subject string, who AccountDevice) error {
	_, err := f.store.GetProfile(ctx, who.Account.ID, kind, subject)
	return err
}

func TestCommunityInfoIsWrittenByOwnerOrAdminAndReadByMembers(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	// A member reads but may not write; a stranger learns nothing.
	if _, _, err := f.putInfo(ctx, ProfileKindCommunity, f.community.ID, "", f.member, 0); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member write err = %v", err)
	}
	if _, _, err := f.putInfo(ctx, ProfileKindCommunity, f.community.ID, "", f.outsider, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider write err = %v", err)
	}
	version, notices, err := f.putInfo(ctx, ProfileKindCommunity, f.community.ID, "", f.owner, 0)
	if err != nil || version != 1 {
		t.Fatalf("owner write version=%d err=%v", version, err)
	}
	// Every community member is told, with info.updated and IDs only.
	told := map[string]bool{}
	for _, n := range notices {
		if n.EventType != InfoUpdatedEventType || n.Payload["subject_kind"] != ProfileKindCommunity || n.Payload["subject_id"] != f.community.ID {
			t.Fatalf("notice = %+v", n)
		}
		told[n.AccountID] = true
	}
	if !told[f.owner.Account.ID] || !told[f.member.Account.ID] || told[f.outsider.Account.ID] || len(told) != 2 {
		t.Fatalf("audience = %v", told)
	}
	var events int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events WHERE event_type = 'info.updated' AND conversation_id IS NULL`).Scan(&events); err != nil || events != 2 {
		t.Fatalf("durable info.updated events = %d err=%v", events, err)
	}
	if err := f.readable(ctx, ProfileKindCommunity, f.community.ID, f.member); err != nil {
		t.Fatalf("member read err = %v", err)
	}
	if err := f.readable(ctx, ProfileKindCommunity, f.community.ID, f.outsider); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider read err = %v", err)
	}
	// A moderator manages members but does not edit community info.
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleModerator); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.putInfo(ctx, ProfileKindCommunity, f.community.ID, "", f.member, 1); !errors.Is(err, ErrForbidden) {
		t.Fatalf("moderator write err = %v", err)
	}
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	if v, _, err := f.putInfo(ctx, ProfileKindCommunity, f.community.ID, "", f.member, 1); err != nil || v != 2 {
		t.Fatalf("admin write version=%d err=%v", v, err)
	}
	// A stale If-Match is a conflict, not an overwrite.
	if _, _, err := f.putInfo(ctx, ProfileKindCommunity, f.community.ID, "", f.owner, 1); !errors.Is(err, ErrProfileVersionConflict) {
		t.Fatalf("stale write err = %v", err)
	}
}

func TestCategoryIsBoundToItsCommunityByTheFirstWrite(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	other, err := f.store.CreateCommunity(ctx, "Other", f.member.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	cat := newCategoryID(t)
	// Only an owner or admin creates a category.
	if _, _, err := f.putInfo(ctx, ProfileKindCategory, cat, f.community.ID, f.member, 0); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member create err = %v", err)
	}
	// An If-Match on an unbound ID is a missing record.
	if _, _, err := f.putInfo(ctx, ProfileKindCategory, cat, f.community.ID, f.owner, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unbound If-Match err = %v", err)
	}
	if v, _, err := f.putInfo(ctx, ProfileKindCategory, cat, f.community.ID, f.owner, 0); err != nil || v != 1 {
		t.Fatalf("create version=%d err=%v", v, err)
	}
	if _, err := f.store.GetCategoryInfo(ctx, f.member.Account.ID, f.community.ID, cat); err != nil {
		t.Fatalf("member read err = %v", err)
	}
	if _, err := f.store.GetCategoryInfo(ctx, f.outsider.Account.ID, f.community.ID, cat); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider read err = %v", err)
	}
	// Through another community's route the category does not exist, for
	// reading and for writing, even to that community's owner.
	if _, err := f.store.GetCategoryInfo(ctx, f.member.Account.ID, other.ID, cat); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-community read err = %v", err)
	}
	if _, _, err := f.putInfo(ctx, ProfileKindCategory, cat, other.ID, f.member, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-community write err = %v", err)
	}
	if _, _, err := f.putInfo(ctx, ProfileKindCategory, cat, other.ID, f.member, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-community rebind err = %v", err)
	}
	// Malformed IDs read as missing.
	if _, _, err := f.putInfo(ctx, ProfileKindCategory, "cat_x", f.community.ID, f.owner, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("bad category id err = %v", err)
	}
	// The abuse bound on bound category IDs.
	for i := 1; i < maxCommunityCategories; i++ {
		if _, err := f.store.db.ExecContext(ctx, `INSERT INTO community_categories(id, community_id, created_by_account_id, created_at) VALUES(?, ?, ?, ?)`,
			fmt.Sprintf("cat_%032x", i), f.community.ID, f.owner.Account.ID, nowString()); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := f.putInfo(ctx, ProfileKindCategory, newCategoryID(t), f.community.ID, f.owner, 0); !errors.Is(err, ErrCategoryLimit) {
		t.Fatalf("over the bound err = %v", err)
	}
}

func TestChannelInfoFollowsWhoCanSeeTheChannel(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	// Open channel: any community member reads and writes (D80); the server
	// leaves an admin restriction to the apps.
	if v, _, err := f.putInfo(ctx, ProfileKindChannel, f.open.ID, "", f.member, 0); err != nil || v != 1 {
		t.Fatalf("member open write version=%d err=%v", v, err)
	}
	if err := f.readable(ctx, ProfileKindChannel, f.open.ID, f.owner); err != nil {
		t.Fatalf("owner open read err = %v", err)
	}
	if err := f.readable(ctx, ProfileKindChannel, f.open.ID, f.outsider); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider open read err = %v", err)
	}
	if _, _, err := f.putInfo(ctx, ProfileKindChannel, f.open.ID, "", f.outsider, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("outsider open write err = %v", err)
	}
	// Private channel: only its own members, and its notices go to them only.
	_, notices, err := f.putInfo(ctx, ProfileKindChannel, f.private.ID, "", f.owner, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(notices) != 1 || notices[0].AccountID != f.owner.Account.ID {
		t.Fatalf("private notices = %+v", notices)
	}
	if err := f.readable(ctx, ProfileKindChannel, f.private.ID, f.member); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member private read err = %v", err)
	}
	if _, _, err := f.putInfo(ctx, ProfileKindChannel, f.private.ID, "", f.member, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member private write err = %v", err)
	}
	if _, err := f.store.ManageConversationMember(ctx, f.privateConv, f.owner.Account.ID, f.member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := f.readable(ctx, ProfileKindChannel, f.private.ID, f.member); err != nil {
		t.Fatalf("private member read err = %v", err)
	}
	if _, notices, err = f.putInfo(ctx, ProfileKindChannel, f.private.ID, "", f.member, 1); err != nil || len(notices) != 2 {
		t.Fatalf("private member write notices=%d err=%v", len(notices), err)
	}
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, f.privateConv, f.member.Account.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.readable(ctx, ProfileKindChannel, f.private.ID, f.member); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed member private read err = %v", err)
	}
	// The kind must match the ID: a channel ID is no community.
	if err := f.readable(ctx, ProfileKindCommunity, f.open.ID, f.owner); !errors.Is(err, ErrNotFound) {
		t.Fatalf("wrong-kind read err = %v", err)
	}
}

func TestLegacyChannelInfoIsReadByItsConversationMembers(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	outsider := registerTestMember(t, ctx, store, invite.Code, "outsider")
	community, err := store.CreateCommunity(ctx, "Legacy", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if community.SharedConversationID != nil {
		t.Fatal("expected the legacy layout")
	}
	channel, _, err := store.CreateChannelWithConversation(ctx, community.ID, "", "", owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.PutProfile(ctx, ProfileWrite{Kind: ProfileKindChannel, SubjectID: channel.ID, WriterAccountID: owner.Account.ID, KeyID: infoKey, Ciphertext: infoBlob()}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetProfile(ctx, owner.Account.ID, ProfileKindChannel, channel.ID); err != nil {
		t.Fatalf("legacy read err = %v", err)
	}
	if _, err := store.GetProfile(ctx, outsider.Account.ID, ProfileKindChannel, channel.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("legacy outsider read err = %v", err)
	}
}

func TestSubjectVersionsListsOnlyReadableInfo(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	cat := newCategoryID(t)
	for _, w := range []struct{ kind, id, community string }{
		{ProfileKindCommunity, f.community.ID, ""},
		{ProfileKindCategory, cat, f.community.ID},
		{ProfileKindChannel, f.open.ID, ""},
		{ProfileKindChannel, f.private.ID, ""},
	} {
		if _, _, err := f.putInfo(ctx, w.kind, w.id, w.community, f.owner, 0); err != nil {
			t.Fatal(err)
		}
	}
	query := ProfileVersionQuery{CommunityIDs: []string{f.community.ID}, CategoryIDs: []string{cat}, ChannelIDs: []string{f.open.ID, f.private.ID}}
	count := func(who AccountDevice) int {
		versions, err := f.store.SubjectVersions(ctx, who.Account.ID, query)
		if err != nil {
			t.Fatal(err)
		}
		return len(versions)
	}
	if got := count(f.owner); got != 4 {
		t.Fatalf("owner versions = %d", got)
	}
	if got := count(f.member); got != 3 {
		t.Fatalf("member versions = %d, want the private channel left out", got)
	}
	if got := count(f.outsider); got != 0 {
		t.Fatalf("outsider versions = %d", got)
	}
	tooMany := make([]string, MaxProfileVersionQuery+1)
	if _, err := f.store.SubjectVersions(ctx, f.owner.Account.ID, ProfileVersionQuery{ChannelIDs: tooMany}); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("oversized query err = %v", err)
	}
}

func TestInfoRecordsGoWithWhatTheyDescribe(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	cat := newCategoryID(t)
	for _, w := range []struct{ kind, id, community string }{
		{ProfileKindCommunity, f.community.ID, ""},
		{ProfileKindCategory, cat, f.community.ID},
		{ProfileKindChannel, f.open.ID, ""},
	} {
		if _, _, err := f.putInfo(ctx, w.kind, w.id, w.community, f.owner, 0); err != nil {
			t.Fatal(err)
		}
	}
	rows := func() int {
		var n int
		if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM encrypted_profiles WHERE subject_kind IN ('community', 'category', 'channel')`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if got := rows(); got != 3 {
		t.Fatalf("rows = %d", got)
	}
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM channels WHERE id = ?`, f.open.ID); err != nil {
		t.Fatal(err)
	}
	if got := rows(); got != 2 {
		t.Fatalf("rows after channel delete = %d", got)
	}
	// Deleting the community cascades to its categories; both records go.
	if _, err := f.store.db.ExecContext(ctx, `PRAGMA foreign_keys = ON`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `DELETE FROM communities WHERE id = ?`, f.community.ID); err != nil {
		t.Fatal(err)
	}
	if got := rows(); got != 0 {
		t.Fatalf("rows after community delete = %d", got)
	}
}

// Owner decision 2026-11-09 (C3): only owners and admins create channels.
func TestOnlyOwnersAndAdminsCreateChannels(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	for _, step := range []struct {
		role string
		err  error
	}{
		{domain.RoleMember, ErrForbidden},
		{domain.RoleModerator, ErrForbidden},
		{domain.RoleAdmin, nil},
	} {
		if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, step.role); err != nil {
			t.Fatal(err)
		}
		_, _, err := f.store.CreateChannelWithConversation(ctx, f.community.ID, "", "", f.member.Account.ID)
		if !errors.Is(err, step.err) {
			t.Fatalf("%s create err = %v, want %v", step.role, err, step.err)
		}
		_, err = f.store.CreateChannel(ctx, f.community.ID, "", "private", f.member.Account.ID)
		if !errors.Is(err, step.err) {
			t.Fatalf("%s legacy create err = %v, want %v", step.role, err, step.err)
		}
	}
}
