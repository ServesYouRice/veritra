package storage

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

// layoutFixture is a community in the active shared-group layout with an open,
// an announcement and a private channel. The owner owns everything, the member
// joined the community, and the outsider belongs to no community.
type layoutFixture struct {
	store        *Store
	owner        AccountDevice
	member       AccountDevice
	outsider     AccountDevice
	community    domain.Community
	open         domain.Channel
	announcement domain.Channel
	private      domain.Channel
	shared       string
	privateConv  string
}

func newLayoutFixture(t *testing.T, ctx context.Context) layoutFixture {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	store.communityLayout = true
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "member")
	outsider := registerTestMember(t, ctx, store, invite.Code, "outsider")
	community, err := store.CreateCommunity(ctx, owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if community.LayoutVersion != CommunityLayoutVersion || community.LayoutGeneration != 1 || community.SharedConversationID == nil {
		t.Fatalf("new community layout = %+v", community)
	}
	f := layoutFixture{store: store, owner: owner, member: member, outsider: outsider, community: community, shared: *community.SharedConversationID}
	var conversation domain.Conversation
	if f.open, conversation, err = store.CreateChannelWithConversation(ctx, community.ID, "", owner.Account.ID); err != nil || conversation.ID != f.shared {
		t.Fatalf("open channel: conversation=%+v err=%v", conversation, err)
	}
	if f.announcement, conversation, err = store.CreateChannelWithConversation(ctx, community.ID, "announcement", owner.Account.ID); err != nil || conversation.ID != f.shared {
		t.Fatalf("announcement channel: conversation=%+v err=%v", conversation, err)
	}
	if f.private, conversation, err = store.CreateChannelWithConversation(ctx, community.ID, "private", owner.Account.ID); err != nil || conversation.ID == f.shared {
		t.Fatalf("private channel: conversation=%+v err=%v", conversation, err)
	}
	f.privateConv = conversation.ID
	if _, err := store.ManageCommunityMember(ctx, community.ID, owner.Account.ID, member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f layoutFixture) metadata(channelID string, generation int64) json.RawMessage {
	fields := map[string]interface{}{"protocol_version": 1, "mls_epoch": 1}
	if channelID != "" {
		fields[EnvelopeChannelKey] = channelID
	}
	if generation != 0 {
		fields[EnvelopeLayoutGenerationKey] = generation
	}
	raw, _ := json.Marshal(fields)
	return raw
}

func (f layoutFixture) post(ctx context.Context, conversationID string, who AccountDevice, key string, metadata json.RawMessage) (domain.MessageEnvelope, error) {
	envelope, _, err := f.store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID: conversationID, SenderAccountID: who.Account.ID, SenderDeviceID: who.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo", CryptoMetadata: metadata,
	})
	return envelope, err
}

func memberCount(t *testing.T, ctx context.Context, store *Store, conversationID string) int {
	t.Helper()
	var n int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE conversation_id = ?`, conversationID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestMigration0049GivesExistingCommunitiesALegacyLayoutAndChangesNothingElse(t *testing.T) {
	ctx := context.Background()
	store, _ := openBareStoreAt(t)
	old, _ := migrationsUpTo(t, "0046")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	now := "2026-01-01T00:00:00Z"
	for _, statement := range []string{
		`INSERT INTO instances(id, name, setup_complete, created_at, updated_at) VALUES(1, 'Old', 1, '` + now + `', '` + now + `')`,
		`INSERT INTO accounts(id, username, password_hash, role, status, created_at) VALUES('acct_a', 'alice', 'h', 'owner', 'active', '` + now + `')`,
		`INSERT INTO devices(id, account_id, name, key_package, created_at) VALUES('dev_a', 'acct_a', 'a', X'01', '` + now + `')`,
		`INSERT INTO communities(id, name, created_by, created_at) VALUES('comm_old', 'Old club', 'acct_a', '` + now + `')`,
		`INSERT INTO channels(id, community_id, name, kind, created_at) VALUES('chan_old', 'comm_old', 'general', 'private', '` + now + `')`,
		`INSERT INTO conversations(id, kind, title, community_id, channel_id, created_by, created_at) VALUES('conv_old', 'community_channel', 'general', 'comm_old', 'chan_old', 'acct_a', '` + now + `')`,
		`INSERT INTO memberships(id, account_id, community_id, role, created_at) VALUES('mbr_c', 'acct_a', 'comm_old', 'owner', '` + now + `')`,
		`INSERT INTO memberships(id, account_id, conversation_id, role, created_at) VALUES('mbr_v', 'acct_a', 'conv_old', 'owner', '` + now + `')`,
		`INSERT INTO message_envelopes(id, conversation_id, sender_account_id, sender_device_id, idempotency_key, ciphertext, crypto_protocol, crypto_metadata_json, attachment_refs_json, created_at) VALUES('msg_old', 'conv_old', 'acct_a', 'dev_a', 'k1', X'C1C2', 'mls10-openmls-v1', '{}', '[]', '` + now + `')`,
	} {
		if _, err := store.db.ExecContext(ctx, statement); err != nil {
			t.Fatalf("seed %q: %v", statement[:30], err)
		}
	}
	snapshot := func() string {
		var parts []string
		for _, query := range []string{
			`SELECT COUNT(*) || ':' || COALESCE(group_concat(id || kind || COALESCE(community_id,'') || COALESCE(channel_id,''), ','), '') FROM conversations`,
			`SELECT COUNT(*) || ':' || COALESCE(group_concat(id || role, ','), '') FROM memberships`,
			`SELECT COUNT(*) || ':' || COALESCE(group_concat(id || hex(ciphertext) || crypto_metadata_json, ','), '') FROM message_envelopes`,
			`SELECT COUNT(*) || ':' || COALESCE(group_concat(id || kind, ','), '') FROM channels`,
		} {
			var part string
			if err := store.db.QueryRowContext(ctx, query).Scan(&part); err != nil {
				t.Fatal(err)
			}
			parts = append(parts, part)
		}
		return strings.Join(parts, "|")
	}
	before := snapshot()
	for i := 0; i < 2; i++ { // the second run is a no-op
		if err := store.Migrate(ctx, migrations.FS); err != nil {
			t.Fatalf("migrate run %d: %v", i, err)
		}
	}
	if after := snapshot(); after != before {
		t.Fatalf("the migration changed existing rows:\nbefore %s\nafter  %s", before, after)
	}
	layout, err := communityLayoutOf(ctx, store.db, "comm_old")
	if err != nil || layout.active {
		t.Fatalf("existing community layout = %+v err=%v, want legacy", layout, err)
	}
	var state string
	var version, routes, conversationLayouts int
	if err := store.db.QueryRowContext(ctx, `SELECT state, version FROM community_layouts WHERE community_id = 'comm_old'`).Scan(&state, &version); err != nil || state != "legacy" || version != 1 {
		t.Fatalf("layout row: state=%q version=%d err=%v", state, version, err)
	}
	_ = store.db.QueryRowContext(ctx, `SELECT (SELECT COUNT(*) FROM community_channel_routes), (SELECT COUNT(*) FROM community_conversation_layouts)`).Scan(&routes, &conversationLayouts)
	if routes != 0 || conversationLayouts != 0 {
		t.Fatalf("legacy community got routes=%d conversation layouts=%d", routes, conversationLayouts)
	}
}

func TestCommunityLayoutSwitchOffKeepsTheLegacyPerChannelLayout(t *testing.T) {
	ctx := context.Background()
	f := newCommunityFixture(t, ctx)
	layout, err := communityLayoutOf(ctx, f.store.db, f.community.ID)
	if err != nil || layout.active {
		t.Fatalf("layout = %+v err=%v, want legacy", layout, err)
	}
	if f.community.LayoutVersion != 0 || f.community.SharedConversationID != nil {
		t.Fatalf("legacy community advertises a layout: %+v", f.community)
	}
	if f.conversation.Kind != "community_channel" || f.conversation.ChannelID == nil {
		t.Fatalf("legacy channel conversation = %+v", f.conversation)
	}
	if _, _, err := f.store.CreateChannelWithConversation(ctx, f.community.ID, ChannelAccessOpen, f.owner.Account.ID); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("open channel in a legacy community: %v", err)
	}
	channels, err := f.store.ListChannels(ctx, f.community.ID, f.insider.Account.ID)
	if err != nil || len(channels) != 1 || channels[0].ConversationID != nil || channels[0].LayoutVersion != 0 || channels[0].Kind != "private" {
		t.Fatalf("legacy channel list = %+v err=%v", channels, err)
	}
	// A message in a legacy channel conversation carries no channel context.
	if _, err := (layoutFixture{store: f.store}).post(ctx, f.conversation.ID, f.owner, "m1", json.RawMessage(`{"channel_id":"chan_x"}`)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("channel_id in a legacy channel conversation: %v", err)
	}
}

func TestActiveLayoutRoutesOpenChannelsToOneSharedGroup(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	if f.open.ConversationID == nil || *f.open.ConversationID != f.shared || f.announcement.ConversationID == nil || *f.announcement.ConversationID != f.shared {
		t.Fatalf("open and announcement channels do not share one group: %+v %+v", f.open, f.announcement)
	}
	if f.private.ConversationID == nil || *f.private.ConversationID != f.privateConv || f.privateConv == f.shared {
		t.Fatalf("private channel route = %+v", f.private)
	}
	if f.open.Kind != "open" || f.announcement.Kind != "announcement" || f.private.Kind != "private" {
		t.Fatalf("kinds = %q %q %q", f.open.Kind, f.announcement.Kind, f.private.Kind)
	}
	// Exactly one shared conversation exists for the community, and no
	// conversation was made for the open and announcement channels.
	var conversations int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations WHERE community_id = ?`, f.community.ID).Scan(&conversations); err != nil || conversations != 2 {
		t.Fatalf("community conversations = %d err=%v, want the shared one and one private", conversations, err)
	}
	// Effective kind is projected wherever a conversation is returned.
	listed, err := f.store.ListConversations(ctx, f.member.Account.ID)
	if err != nil || len(listed) != 1 || listed[0].ID != f.shared || listed[0].Kind != CommunityShared || listed[0].ChannelID != nil || listed[0].PostingRestricted {
		t.Fatalf("member conversations = %+v err=%v", listed, err)
	}
	byID, err := f.store.ConversationByID(ctx, f.shared)
	if err != nil || byID.Kind != CommunityShared || byID.ChannelID != nil {
		t.Fatalf("by id = %+v err=%v", byID, err)
	}
	ownerList, err := f.store.ListConversations(ctx, f.owner.Account.ID)
	if err != nil || len(ownerList) != 2 {
		t.Fatalf("owner conversations = %+v err=%v", ownerList, err)
	}
	for _, c := range ownerList {
		if (c.ID == f.shared) != (c.Kind == CommunityShared) {
			t.Fatalf("kind projection wrong: %+v", c)
		}
	}
	retention := int64(3600)
	updated, err := f.store.UpdateConversationRetention(ctx, f.shared, f.owner.Account.ID, &retention)
	if err != nil || updated.Kind != CommunityShared {
		t.Fatalf("retention response = %+v err=%v", updated, err)
	}
	communities, err := f.store.ListCommunities(ctx, f.member.Account.ID)
	if err != nil || len(communities) != 1 || communities[0].SharedConversationID == nil || *communities[0].SharedConversationID != f.shared || communities[0].LayoutGeneration != 1 {
		t.Fatalf("communities = %+v err=%v", communities, err)
	}
}

func TestActiveLayoutJoinAddsExactlyTheSharedMembership(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	if member, _ := f.store.IsConversationMember(ctx, f.shared, f.member.Account.ID); !member {
		t.Fatal("a new community member is not in the shared conversation")
	}
	if member, _ := f.store.IsConversationMember(ctx, f.privateConv, f.member.Account.ID); member {
		t.Fatal("a new community member was put into a private channel")
	}
	var memberships int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE account_id = ? AND conversation_id IS NOT NULL`, f.member.Account.ID).Scan(&memberships); err != nil || memberships != 1 {
		t.Fatalf("conversation memberships of the new member = %d err=%v, want 1", memberships, err)
	}
	// A role change keeps the shared membership in step and still touches no
	// private channel.
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleModerator); err != nil {
		t.Fatal(err)
	}
	if role, err := f.store.ConversationMemberRole(ctx, f.shared, f.member.Account.ID); err != nil || role != domain.RoleModerator {
		t.Fatalf("shared role = %q err=%v", role, err)
	}
	if member, _ := f.store.IsConversationMember(ctx, f.privateConv, f.member.Account.ID); member {
		t.Fatal("a role change put the member into a private channel")
	}
	// The shared roster is the community's: it cannot be edited directly.
	if _, err := f.store.ManageConversationMember(ctx, f.shared, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("direct add to the shared conversation: %v", err)
	}
}

func TestActiveLayoutPrivateChannelVisibleOnlyToItsMembers(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	names := func(who AccountDevice) string {
		channels, err := f.store.ListChannels(ctx, f.community.ID, who.Account.ID)
		if err != nil {
			t.Fatal(err)
		}
		// Channels carry no names (C3): label them by the fixture's IDs.
		labels := map[string]string{f.open.ID: "general", f.announcement.ID: "news", f.private.ID: "secret"}
		var out []string
		for _, c := range channels {
			out = append(out, labels[c.ID])
		}
		return strings.Join(out, ",")
	}
	if got := names(f.owner); got != "general,news,secret" {
		t.Fatalf("owner channels = %q", got)
	}
	if got := names(f.member); got != "general,news" {
		t.Fatalf("member channels = %q, want the private one hidden", got)
	}
	if _, err := f.store.ListChannels(ctx, f.community.ID, f.outsider.Account.ID); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider channel list: %v", err)
	}
	// The owner picks the private channel's members through the existing
	// conversation route; it refuses someone outside the community.
	if _, err := f.store.ManageConversationMember(ctx, f.privateConv, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("outsider added to a private channel: %v", err)
	}
	if _, err := f.store.ManageConversationMember(ctx, f.privateConv, f.owner.Account.ID, f.member.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add community member to a private channel: %v", err)
	}
	if got := names(f.member); got != "general,news,secret" {
		t.Fatalf("member channels after joining = %q", got)
	}
}

func TestActiveLayoutRefusesAConversationMadeOutsideTheLayout(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	_, _, err := f.store.CreateOrGetConversation(ctx, CreateConversationInput{
		Kind: "community_channel", CommunityID: &f.community.ID, ChannelID: &f.open.ID, CreatedBy: f.owner.Account.ID,
	})
	if !errors.Is(err, ErrForbidden) {
		t.Fatalf("POST /conversations for a routed community: %v", err)
	}
	if _, _, err := f.store.SetConversationPostingPolicy(ctx, f.shared, f.owner.Account.ID, PostingPolicyAdmins); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("whole-group posting policy on the shared conversation: %v", err)
	}
}

func TestActiveLayoutPostsMustNameAnOpenChannelOfTheirGroup(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	// A second community with its own shared group and channel.
	other, err := f.store.CreateCommunity(ctx, f.owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	foreign, _, err := f.store.CreateChannelWithConversation(ctx, other.ID, "", f.owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "ok1", f.metadata(f.open.ID, 1)); err != nil {
		t.Fatalf("post in an open channel: %v", err)
	}
	if _, err := f.post(ctx, f.shared, f.member, "ok2", f.metadata(f.open.ID, 1)); err != nil {
		t.Fatalf("second post: %v", err)
	}
	for name, metadata := range map[string]json.RawMessage{
		"no context":             json.RawMessage(`{"mls_epoch":1}`),
		"empty metadata":         nil,
		"no channel":             f.metadata("", 1),
		"no generation":          f.metadata(f.open.ID, 0),
		"stale generation":       f.metadata(f.open.ID, 2),
		"foreign channel":        f.metadata(foreign.ID, 1),
		"private channel":        f.metadata(f.private.ID, 1),
		"unknown channel":        f.metadata("chan_missing", 1),
		"channel not string":     json.RawMessage(`{"channel_id":7,"community_layout_generation":1}`),
		"generation string":      json.RawMessage(`{"channel_id":"` + f.open.ID + `","community_layout_generation":"1"}`),
		"metadata not an object": json.RawMessage(`[]`),
	} {
		if _, err := f.post(ctx, f.shared, f.member, "bad-"+name, metadata); !errors.Is(err, ErrInvalidChannelRoute) {
			t.Errorf("%s: err = %v, want %v", name, err, ErrInvalidChannelRoute)
		}
	}
	// The foreign community's channel cannot be reached through this group,
	// nor this one's through the other group.
	if _, err := f.post(ctx, *foreign.ConversationID, f.owner, "cross", f.metadata(f.open.ID, 1)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("channel of another community: %v", err)
	}
	var stored int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM message_envelopes`).Scan(&stored); err != nil || stored != 2 {
		t.Fatalf("stored envelopes = %d err=%v, want only the two valid posts", stored, err)
	}
	// An idempotent retry still answers.
	if _, err := f.post(ctx, f.shared, f.member, "ok1", f.metadata(f.open.ID, 1)); err != nil {
		t.Fatalf("idempotent replay: %v", err)
	}
}

func TestActiveLayoutChannelContextIsRefusedOutsideSharedGroups(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	group, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.post(ctx, f.privateConv, f.owner, "p-ok", f.metadata("", 0)); err != nil {
		t.Fatalf("private channel post without context: %v", err)
	}
	if _, err := f.post(ctx, group.ID, f.owner, "g-ok", f.metadata("", 0)); err != nil {
		t.Fatalf("group post without context: %v", err)
	}
	for _, target := range []string{f.privateConv, group.ID} {
		for name, metadata := range map[string]json.RawMessage{
			"channel":    f.metadata(f.open.ID, 0),
			"generation": f.metadata("", 1),
			"both":       f.metadata(f.open.ID, 1),
		} {
			if _, err := f.post(ctx, target, f.owner, "x-"+target+name, metadata); !errors.Is(err, ErrInvalidChannelRoute) {
				t.Errorf("%s with %s context: err = %v", target, name, err)
			}
		}
	}
}

func TestActiveLayoutAnnouncementChannelRefusesMemberPostsInTheSharedGroup(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	if _, err := f.post(ctx, f.shared, f.member, "n1", f.metadata(f.announcement.ID, 1)); !errors.Is(err, ErrPostingRestricted) {
		t.Fatalf("member post in an announcement channel: %v", err)
	}
	if _, err := f.post(ctx, f.shared, f.owner, "n2", f.metadata(f.announcement.ID, 1)); err != nil {
		t.Fatalf("owner post in an announcement channel: %v", err)
	}
	// The same member still posts in the open channel of the same group.
	if _, err := f.post(ctx, f.shared, f.member, "n3", f.metadata(f.open.ID, 1)); err != nil {
		t.Fatalf("member post in the open channel: %v", err)
	}
	// An outsider is not a member of the shared group at all.
	if _, err := f.post(ctx, f.shared, f.outsider, "n4", f.metadata(f.open.ID, 1)); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider post: %v", err)
	}
}

func TestActiveLayoutRepliesStayInTheirChannel(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	second, _, err := f.store.CreateChannelWithConversation(ctx, f.community.ID, "open", f.owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	root, err := f.post(ctx, f.shared, f.owner, "r1", f.metadata(f.open.ID, 1))
	if err != nil {
		t.Fatal(err)
	}
	reply := func(key, channelID string, asThread bool) error {
		envelope := domain.MessageEnvelope{
			ConversationID: f.shared, SenderAccountID: f.member.Account.ID, SenderDeviceID: f.member.Device.ID,
			IdempotencyKey: key, Ciphertext: []byte("x"), CryptoProtocol: "mls-openmls-todo", CryptoMetadata: f.metadata(channelID, 1),
		}
		if asThread {
			envelope.ThreadRootID = &root.ID
		} else {
			envelope.ReplyToID = &root.ID
		}
		_, _, err := f.store.SaveMessageEnvelope(ctx, envelope)
		return err
	}
	if err := reply("a", f.open.ID, false); err != nil {
		t.Fatalf("reply in the same channel: %v", err)
	}
	if err := reply("b", f.open.ID, true); err != nil {
		t.Fatalf("thread in the same channel: %v", err)
	}
	if err := reply("c", second.ID, false); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("reply across channels: %v", err)
	}
	if err := reply("d", second.ID, true); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("thread across channels: %v", err)
	}
}

func TestActiveLayoutEditAndDeleteKeepTheChannel(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	second, _, err := f.store.CreateChannelWithConversation(ctx, f.community.ID, "open", f.owner.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	post, err := f.post(ctx, f.shared, f.member, "e1", f.metadata(f.open.ID, 1))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.UpdateMessageEnvelope(ctx, post.ID, f.member.Account.ID, []byte("y"), "mls-openmls-todo", f.metadata(second.ID, 1)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("edit that moves the post: %v", err)
	}
	if _, err := f.store.UpdateMessageEnvelope(ctx, post.ID, f.member.Account.ID, []byte("y"), "mls-openmls-todo", f.metadata(f.open.ID, 2)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("edit that changes the generation: %v", err)
	}
	edited, err := f.store.UpdateMessageEnvelope(ctx, post.ID, f.member.Account.ID, []byte("y"), "mls-openmls-todo", json.RawMessage(`{"mls_epoch":2}`))
	if err != nil {
		t.Fatalf("edit without route keys: %v", err)
	}
	var fields map[string]interface{}
	if err := json.Unmarshal(edited.CryptoMetadata, &fields); err != nil || fields[EnvelopeChannelKey] != f.open.ID || fields[EnvelopeLayoutGenerationKey] != float64(1) || fields["mls_epoch"] != float64(2) {
		t.Fatalf("edited metadata = %s err=%v, want the stored route kept", edited.CryptoMetadata, err)
	}
	deleted, err := f.store.DeleteMessageEnvelope(ctx, post.ID, f.member.Account.ID, []byte("z"), "mls-openmls-todo", nil)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}
	fields = nil
	if err := json.Unmarshal(deleted.CryptoMetadata, &fields); err != nil || fields[EnvelopeChannelKey] != f.open.ID || fields["deleted"] != true {
		t.Fatalf("delete marker metadata = %s err=%v", deleted.CryptoMetadata, err)
	}
	// A message outside a shared group cannot gain a channel by an edit.
	own, err := f.post(ctx, f.privateConv, f.owner, "e2", f.metadata("", 0))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.UpdateMessageEnvelope(ctx, own.ID, f.owner.Account.ID, []byte("y"), "mls-openmls-todo", f.metadata(f.open.ID, 1)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("edit that adds a channel to a private-channel post: %v", err)
	}
}

func TestActiveLayoutMemberLimitAppliesToTheSharedGroup(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	f.store.limits.ConversationMembers = memberCount(t, ctx, f.store, f.shared)
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.outsider.Account.ID, domain.RoleMember); !errors.Is(err, ErrConversationMemberLimit) {
		t.Fatalf("a join over the member limit: err = %v, want %v", err, ErrConversationMemberLimit)
	}
	if member, _ := f.store.IsConversationMember(ctx, f.shared, f.outsider.Account.ID); member {
		t.Fatal("a refused join left a membership")
	}
}

func TestActiveLayoutRefusesARepeatedChannelKey(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	gen := `"community_layout_generation":1`
	repeated := func(first, second string) json.RawMessage {
		return json.RawMessage(`{"channel_id":"` + first + `","channel_id":"` + second + `",` + gen + `}`)
	}
	for name, metadata := range map[string]json.RawMessage{
		"announcement then open": repeated(f.announcement.ID, f.open.ID),
		"open then announcement": repeated(f.open.ID, f.announcement.ID),
		"same channel twice":     repeated(f.open.ID, f.open.ID),
		"repeated generation":    json.RawMessage(`{"channel_id":"` + f.open.ID + `",` + gen + `,` + gen + `}`),
		// A repeated mls_epoch is refused earlier, by the epoch rule (review
		// L2, TestC7EpochMetadataIsANonNegativeInteger); any other key here.
		"repeated other key": json.RawMessage(`{"protocol_version":1,"protocol_version":2,"channel_id":"` + f.open.ID + `",` + gen + `}`),
	} {
		if _, err := f.post(ctx, f.shared, f.member, "dup-"+name, metadata); !errors.Is(err, ErrInvalidChannelRoute) {
			t.Errorf("%s: err = %v, want %v", name, err, ErrInvalidChannelRoute)
		}
	}
	// Nested objects may repeat names of their own; only the top level counts.
	nested := json.RawMessage(`{"channel_id":"` + f.open.ID + `",` + gen + `,"extra":{"a":1,"a":2}}`)
	post, err := f.post(ctx, f.shared, f.member, "nested", nested)
	if err != nil {
		t.Fatalf("repeated key inside a nested object: %v", err)
	}
	// An edit cannot introduce a repeated key either.
	if _, err := f.store.UpdateMessageEnvelope(ctx, post.ID, f.member.Account.ID, []byte("y"), "mls-openmls-todo", repeated(f.open.ID, f.open.ID)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("edit with a repeated channel key: %v", err)
	}
	// A repeated route key outside a shared group stays refused as before.
	if _, err := f.post(ctx, f.privateConv, f.owner, "dup-private", repeated(f.open.ID, f.open.ID)); !errors.Is(err, ErrInvalidChannelRoute) {
		t.Fatalf("repeated channel key in a private channel: %v", err)
	}
	// Every stored row reads, through SQLite, the channel admission checked.
	rows, err := f.store.db.QueryContext(ctx, `SELECT json_extract(crypto_metadata_json, '$.channel_id') FROM message_envelopes`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	seen := 0
	for rows.Next() {
		var channelID string
		if err := rows.Scan(&channelID); err != nil || channelID != f.open.ID {
			t.Fatalf("stored channel = %q err=%v, want %q", channelID, err, f.open.ID)
		}
		seen++
	}
	if seen != 1 {
		t.Fatalf("stored envelopes = %d, want only the nested-object post", seen)
	}
}

func TestActiveLayoutSearchHidesPrivateChannelsFromNonMembers(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	// C3 (migration 0082) removed community and channel names from the
	// server, so metadata search returns accounts only: no community or
	// channel row may come back for anyone, member or not, before or after
	// joining a private channel, whatever the query (ids, kinds, prefixes).
	queries := []string{
		f.community.ID, f.private.ID, f.open.ID, f.announcement.ID,
		f.privateConv, f.shared, "private", "sec", "secret", "gen", "general", "announcement",
	}
	assertNoCommunityRows := func(stage string) {
		t.Helper()
		for _, who := range []AccountDevice{f.owner, f.member, f.outsider} {
			for _, q := range queries {
				results, err := f.store.SearchMetadata(ctx, who.Account.ID, q, 50, 0)
				if err != nil {
					t.Fatal(err)
				}
				for _, r := range results {
					if r.Type != "account" {
						t.Fatalf("%s: search %q by %s returned a %s row: %+v", stage, q, who.Account.Username, r.Type, r)
					}
				}
			}
		}
	}
	assertNoCommunityRows("before joining")
	if _, err := f.store.ManageConversationMember(ctx, f.privateConv, f.owner.Account.ID, f.member.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	assertNoCommunityRows("after joining")
	// Exact username lookup still works inside a community.
	results, err := f.store.SearchMetadata(ctx, f.member.Account.ID, "outsider", 20, 0)
	if err != nil || len(results) != 1 || results[0].Type != "account" || results[0].ID != f.outsider.Account.ID {
		t.Fatalf("exact username search = %+v err=%v", results, err)
	}
}

func TestActiveLayoutDemotionReachesPrivateChannelRoles(t *testing.T) {
	ctx := context.Background()
	f := newLayoutFixture(t, ctx)
	third := f.outsider
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, third.Account.ID, domain.RoleMember); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	// The promotion alone adds no private-channel membership.
	if in, _ := f.store.IsConversationMember(ctx, f.privateConv, f.member.Account.ID); in {
		t.Fatal("promotion put the member into a private channel")
	}
	if _, err := f.store.ManageConversationMember(ctx, f.privateConv, f.owner.Account.ID, f.member.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	if role, err := f.store.ConversationMemberRole(ctx, f.privateConv, f.member.Account.ID); err != nil || role != domain.RoleAdmin {
		t.Fatalf("private role = %q err=%v", role, err)
	}
	var before int64
	if err := f.store.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM sync_events`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	eventIDs, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, f.member.Account.ID, domain.RoleMember)
	if err != nil {
		t.Fatal(err)
	}
	if len(eventIDs) != 2 {
		t.Fatalf("events = %v, want the shared and the private membership", eventIDs)
	}
	for _, conversationID := range []string{f.shared, f.privateConv} {
		if role, err := f.store.ConversationMemberRole(ctx, conversationID, f.member.Account.ID); err != nil || role != domain.RoleMember {
			t.Fatalf("role in %s = %q err=%v, want member", conversationID, role, err)
		}
	}
	var events int
	if err := f.store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events WHERE id > ? AND event_type = 'membership.updated' AND conversation_id = ? AND account_id = ?`, before, f.privateConv, f.member.Account.ID).Scan(&events); err != nil || events != 1 {
		t.Fatalf("private membership.updated events = %d err=%v", events, err)
	}
	// The demoted account can no longer manage the private channel.
	if _, err := f.store.ManageConversationMember(ctx, f.privateConv, f.member.Account.ID, third.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("demoted admin added to a private channel: %v", err)
	}
	// A role change adds no membership in private channels the target is not in.
	if in, _ := f.store.IsConversationMember(ctx, f.privateConv, third.Account.ID); in {
		t.Fatal("a role change put an account into a private channel")
	}
	if _, err := f.store.ManageCommunityMember(ctx, f.community.ID, f.owner.Account.ID, third.Account.ID, domain.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	if in, _ := f.store.IsConversationMember(ctx, f.privateConv, third.Account.ID); in {
		t.Fatal("a promotion put an account into a private channel")
	}
}
