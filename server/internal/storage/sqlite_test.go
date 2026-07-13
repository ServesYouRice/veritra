package storage

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/migrations"
)

func TestInviteDeviceAndEncryptedEnvelopeFlow(t *testing.T) {
	ctx := context.Background()
	store, cfg := newTestStore(t, ctx)
	defer store.Close()

	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	memberHash, _ := auth.HashPassword("member-password-123")
	member, err := store.RegisterWithInvite(ctx, RegisterInput{
		InviteCode:   invite.Code,
		Username:     "Member",
		PasswordHash: memberHash,
		DeviceName:   "Member phone",
		KeyPackage:   []byte("member-key-package"),
	})
	if err != nil {
		t.Fatalf("register with invite: %v", err)
	}
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	if err := store.AddConversationMember(ctx, conversation.ID, member.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add member: %v", err)
	}
	msg, duplicate, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  conversation.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "send-1",
		Ciphertext:      []byte("ciphertext bytes only"),
		CryptoProtocol:  "mls-openmls-todo",
	})
	if err != nil {
		t.Fatalf("save message: %v", err)
	}
	if duplicate {
		t.Fatal("first send should not be duplicate")
	}
	msg2, duplicate, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  conversation.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "send-1",
		Ciphertext:      []byte("different ciphertext ignored by idempotency"),
		CryptoProtocol:  "mls-openmls-todo",
	})
	if err != nil {
		t.Fatalf("duplicate save: %v", err)
	}
	if !duplicate || msg2.ID != msg.ID {
		t.Fatalf("expected idempotent duplicate, got duplicate=%v id=%s want=%s", duplicate, msg2.ID, msg.ID)
	}
	messages, err := store.ListMessages(ctx, conversation.ID, member.Account.ID, ListMessagesOptions{Limit: 10})
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(messages) != 1 || !bytes.Equal(messages[0].Ciphertext, []byte("ciphertext bytes only")) {
		t.Fatalf("unexpected messages: %#v", messages)
	}

	plaintext := runtimeSentinel(t)
	dbBytes, err := os.ReadFile(cfg.DatabasePath)
	if err != nil {
		t.Fatalf("read db: %v", err)
	}
	if bytes.Contains(dbBytes, []byte(plaintext)) {
		t.Fatal("database contains runtime plaintext sentinel")
	}
}

func TestConversationRetentionPolicyMetadataPersists(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	retention := int64(86400)
	created, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, RetentionSeconds: &retention})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	conversations, err := store.ListConversations(ctx, owner.Account.ID)
	if err != nil {
		t.Fatalf("list conversations: %v", err)
	}
	if len(conversations) != 1 || conversations[0].ID != created.ID {
		t.Fatalf("unexpected conversations: %#v", conversations)
	}
	if conversations[0].RetentionSeconds == nil || *conversations[0].RetentionSeconds != retention {
		t.Fatalf("retention not persisted: %#v", conversations[0].RetentionSeconds)
	}
}

func TestListConversationsActivityOrderingAndUnread(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "Member")

	// Two conversations; a message is sent in "older" first, then "newer",
	// so activity ordering must surface "newer" ahead of "older".
	older, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatalf("create older conversation: %v", err)
	}
	if err := store.AddConversationMember(ctx, older.ID, member.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add member to older: %v", err)
	}
	newer, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatalf("create newer conversation: %v", err)
	}
	if err := store.AddConversationMember(ctx, newer.ID, member.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add member to newer: %v", err)
	}

	olderMsg, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  older.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "older-1",
		Ciphertext:      []byte("older ciphertext"),
		CryptoProtocol:  "mls-openmls-todo",
	})
	if err != nil {
		t.Fatalf("save older message: %v", err)
	}
	time.Sleep(2 * time.Millisecond)
	if _, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  newer.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "newer-1",
		Ciphertext:      []byte("newer ciphertext"),
		CryptoProtocol:  "mls-openmls-todo",
	}); err != nil {
		t.Fatalf("save newer message: %v", err)
	}

	// Member sees the most recently active conversation first and both
	// unread (the owner sent them).
	memberList, err := store.ListConversations(ctx, member.Account.ID)
	if err != nil {
		t.Fatalf("list for member: %v", err)
	}
	if len(memberList) != 2 {
		t.Fatalf("expected 2 conversations, got %d", len(memberList))
	}
	if memberList[0].ID != newer.ID || memberList[1].ID != older.ID {
		t.Fatalf("activity ordering wrong: got %s then %s", memberList[0].ID, memberList[1].ID)
	}
	if memberList[0].LastMessageAt == nil || memberList[1].LastMessageAt == nil {
		t.Fatalf("last_message_at not populated: %#v", memberList)
	}
	for _, c := range memberList {
		if c.UnreadCount != 1 {
			t.Fatalf("expected unread 1 for %s, got %d", c.ID, c.UnreadCount)
		}
	}

	// The owner authored both messages, so nothing is unread for them.
	ownerList, err := store.ListConversations(ctx, owner.Account.ID)
	if err != nil {
		t.Fatalf("list for owner: %v", err)
	}
	for _, c := range ownerList {
		if c.UnreadCount != 0 {
			t.Fatalf("owner should have no unread, got %d for %s", c.UnreadCount, c.ID)
		}
	}

	// After the member reads the older conversation, its badge clears while
	// the newer one stays unread.
	if err := store.MarkRead(ctx, older.ID, member.Account.ID, olderMsg.ID); err != nil {
		t.Fatalf("mark read: %v", err)
	}
	afterRead, err := store.ListConversations(ctx, member.Account.ID)
	if err != nil {
		t.Fatalf("list after read: %v", err)
	}
	unreadByID := map[string]int64{}
	for _, c := range afterRead {
		unreadByID[c.ID] = c.UnreadCount
	}
	if unreadByID[older.ID] != 0 {
		t.Fatalf("older should be read, got %d", unreadByID[older.ID])
	}
	if unreadByID[newer.ID] != 1 {
		t.Fatalf("newer should stay unread, got %d", unreadByID[newer.ID])
	}
}

func TestExpiredMessagesAreHiddenAndPruned(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	expiringConversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	expiredAt := time.Now().UTC().Add(-time.Hour)
	expired, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  expiringConversation.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "expired-message",
		Ciphertext:      []byte("expired ciphertext"),
		CryptoProtocol:  "mls-openmls-todo",
		ExpiresAt:       &expiredAt,
	})
	if err != nil {
		t.Fatalf("save expired message: %v", err)
	}
	messages, err := store.ListMessages(ctx, expiringConversation.ID, owner.Account.ID, ListMessagesOptions{Limit: 10})
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(messages) != 0 {
		t.Fatalf("expired message should be hidden: %#v", messages)
	}
	if _, err := store.MessageByID(ctx, expired.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired message lookup err=%v want %v", err, ErrNotFound)
	}
	removed, err := store.PruneExpiredMessages(ctx, time.Now().UTC())
	if err != nil {
		t.Fatalf("prune expired messages: %v", err)
	}
	if removed != 1 {
		t.Fatalf("removed=%d want 1", removed)
	}
}

func TestRetentionCapsMessageExpiry(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	retention := int64(60)
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, RetentionSeconds: &retention})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	clientExpiry := time.Now().UTC().Add(time.Hour)
	msg, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  conversation.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "retention-capped",
		Ciphertext:      []byte("retention ciphertext"),
		CryptoProtocol:  "mls-openmls-todo",
		ExpiresAt:       &clientExpiry,
	})
	if err != nil {
		t.Fatalf("save retention-capped message: %v", err)
	}
	if msg.ExpiresAt == nil {
		t.Fatal("expected retention to set expires_at")
	}
	if msg.ExpiresAt.Sub(msg.CreatedAt) > time.Duration(retention)*time.Second+time.Second {
		t.Fatalf("expires_at not capped by retention: created=%s expires=%s", msg.CreatedAt, msg.ExpiresAt)
	}
}

func TestFixedWidthTimestampStringsSortChronologically(t *testing.T) {
	wholeSecond := formatTime(time.Date(2026, 5, 29, 12, 0, 5, 0, time.UTC))
	halfSecond := formatTime(time.Date(2026, 5, 29, 12, 0, 5, 500_000_000, time.UTC))
	nextSecond := formatTime(time.Date(2026, 5, 29, 12, 0, 6, 0, time.UTC))

	if wholeSecond >= halfSecond || halfSecond >= nextSecond {
		t.Fatalf("timestamps do not sort chronologically: %q %q %q", wholeSecond, halfSecond, nextSecond)
	}
	if !strings.Contains(wholeSecond, ".000000000Z") {
		t.Fatalf("whole-second timestamp is not fixed width: %q", wholeSecond)
	}
}

func TestMessageMarkersSyncSearchExportAndMembershipGuards(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "member")
	outsider := registerTestMember(t, ctx, store, invite.Code, "outsider")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	if err := store.AddConversationMember(ctx, conversation.ID, member.Account.ID, domain.RoleMember); err != nil {
		t.Fatalf("add member: %v", err)
	}
	msg, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  conversation.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "marker-flow",
		Ciphertext:      []byte("ciphertext-v1"),
		CryptoProtocol:  "mls-openmls-todo",
	})
	if err != nil {
		t.Fatalf("save message: %v", err)
	}
	if _, err := store.UpdateMessageEnvelope(ctx, msg.ID, member.Account.ID, []byte("member edit"), "mls-openmls-todo", nil); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member edit err=%v want %v", err, ErrForbidden)
	}
	edited, err := store.UpdateMessageEnvelope(ctx, msg.ID, owner.Account.ID, []byte("ciphertext-v2"), "mls-openmls-todo", json.RawMessage(`{"revision":2}`))
	if err != nil {
		t.Fatalf("edit message: %v", err)
	}
	if edited.EditedAt == nil || !bytes.Equal(edited.Ciphertext, []byte("ciphertext-v2")) {
		t.Fatalf("edit not persisted: %#v", edited)
	}
	if err := store.CreateReaction(ctx, msg.ID, member.Account.ID, []byte("encrypted reaction")); err != nil {
		t.Fatalf("create reaction: %v", err)
	}
	if err := store.MarkRead(ctx, conversation.ID, member.Account.ID, msg.ID); err != nil {
		t.Fatalf("mark read: %v", err)
	}
	if _, err := store.CreateCallSession(ctx, conversation.ID, outsider.Account.ID, nil); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider call err=%v want %v", err, ErrNotMember)
	}
	if _, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
		OwnerAccountID:   outsider.Account.ID,
		ConversationID:   &conversation.ID,
		StorageKey:       "blob_outsider",
		CiphertextSHA256: "sha",
		SizeBytes:        12,
	}); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider attachment err=%v want %v", err, ErrNotMember)
	}
	deleted, err := store.DeleteMessageEnvelope(ctx, msg.ID, owner.Account.ID, []byte("encrypted delete marker"), "mls-openmls-todo", nil)
	if err != nil {
		t.Fatalf("delete message: %v", err)
	}
	if deleted.DeletedAt == nil || !bytes.Equal(deleted.Ciphertext, []byte("encrypted delete marker")) {
		t.Fatalf("delete marker not persisted: %#v", deleted)
	}
	eventID, err := store.SaveSyncEvent(ctx, "message.envelope.deleted", nil, conversation.ID, deleted)
	if err != nil {
		t.Fatalf("save sync event: %v", err)
	}
	events, err := store.ListSyncEvents(ctx, member.Account.ID, 0, 10)
	if err != nil {
		t.Fatalf("list sync events: %v", err)
	}
	if len(events) != 1 || events[0].ID != eventID {
		t.Fatalf("unexpected sync events: %#v", events)
	}
	results, err := store.SearchMetadata(ctx, owner.Account.ID, "owner", 10, 0)
	if err != nil {
		t.Fatalf("metadata search: %v", err)
	}
	if len(results) == 0 || results[0].Type != "account" {
		t.Fatalf("unexpected metadata search results: %#v", results)
	}
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "backup_blob", 64, json.RawMessage(`{"kdf":"test"}`)); err != nil {
		t.Fatalf("create backup blob: %v", err)
	}
	export, err := store.ExportAccount(ctx, owner.Account.ID, ExportAccountOptions{})
	if err != nil {
		t.Fatalf("export account: %v", err)
	}
	if export.Account.ID != owner.Account.ID || len(export.Messages) != 1 {
		t.Fatalf("unexpected export: %#v", export)
	}
	if err := store.DeleteAccount(ctx, member.Account.ID); err != nil {
		t.Fatalf("delete account: %v", err)
	}
}

func TestMetadataSearchRanksAndPaginatesAllowedLabelsOnly(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)

	alphaCommunity, err := store.CreateCommunity(ctx, "Alpha", owner.Account.ID)
	if err != nil {
		t.Fatalf("create alpha community: %v", err)
	}
	if _, err := store.CreateChannel(ctx, alphaCommunity.ID, "Alpine", "private", owner.Account.ID); err != nil {
		t.Fatalf("create alpine channel: %v", err)
	}
	if _, err := store.CreateCommunity(ctx, "Team Alpha", owner.Account.ID); err != nil {
		t.Fatalf("create team alpha community: %v", err)
	}

	firstPage, err := store.SearchMetadata(ctx, owner.Account.ID, "alpha", 2, 0)
	if err != nil {
		t.Fatalf("first page metadata search: %v", err)
	}
	if len(firstPage) != 1 {
		t.Fatalf("first page len=%d want 1: %#v", len(firstPage), firstPage)
	}
	if firstPage[0].Type != "community" || firstPage[0].Label != "Alpha" {
		t.Fatalf("exact match should rank first: %#v", firstPage)
	}

	secondPage, err := store.SearchMetadata(ctx, owner.Account.ID, "alpha", 2, 2)
	if err != nil {
		t.Fatalf("second page metadata search: %v", err)
	}
	if len(secondPage) != 0 {
		t.Fatalf("unexpected second page results: %#v", secondPage)
	}

	teamPrefixResults, err := store.SearchMetadata(ctx, owner.Account.ID, "team", 10, 0)
	if err != nil {
		t.Fatalf("team prefix metadata search: %v", err)
	}
	if len(teamPrefixResults) != 1 || teamPrefixResults[0].Label != "Team Alpha" {
		t.Fatalf("prefix query should find Team Alpha: %#v", teamPrefixResults)
	}

	prefixResults, err := store.SearchMetadata(ctx, owner.Account.ID, "alp", 10, 0)
	if err != nil {
		t.Fatalf("prefix metadata search: %v", err)
	}
	if len(prefixResults) < 2 || prefixResults[0].Label != "Alpha" || prefixResults[1].Label != "Alpine" {
		t.Fatalf("prefix results not ranked by label: %#v", prefixResults)
	}

	ciphertextResults, err := store.SearchMetadata(ctx, owner.Account.ID, "ciphertext", 10, 0)
	if err != nil {
		t.Fatalf("ciphertext metadata search: %v", err)
	}
	if len(ciphertextResults) != 0 {
		t.Fatalf("metadata search should not inspect messages: %#v", ciphertextResults)
	}
}

func TestMetadataSearchDoesNotEnumerateAccountsBySubstring(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	target := registerTestMember(t, ctx, store, invite.Code, "charlietarget")

	// A prefix/substring of an unrelated account's username must not reveal it,
	// otherwise any authenticated user could walk the substring space and dump
	// the entire user directory.
	for _, q := range []string{"char", "charlie", "harli", "target"} {
		results, err := store.SearchMetadata(ctx, owner.Account.ID, q, 50, 0)
		if err != nil {
			t.Fatalf("search %q: %v", q, err)
		}
		for _, r := range results {
			if r.Type == "account" && r.ID == target.Account.ID {
				t.Fatalf("substring query %q leaked unrelated account: %#v", q, r)
			}
		}
	}

	// Exact (case-insensitive) username lookup still works so a user can find a
	// known contact to start a conversation.
	exact, err := store.SearchMetadata(ctx, owner.Account.ID, "CharlieTarget", 50, 0)
	if err != nil {
		t.Fatalf("exact search: %v", err)
	}
	found := false
	for _, r := range exact {
		if r.Type == "account" && r.ID == target.Account.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("exact username lookup should find the account: %#v", exact)
	}
}

func TestExpiredInviteCannotRegister(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	expired := time.Now().UTC().Add(-time.Hour)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, &expired)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	hash, _ := auth.HashPassword("member-password-123")
	_, err = store.RegisterWithInvite(ctx, RegisterInput{InviteCode: invite.Code, Username: "late", PasswordHash: hash, DeviceName: "phone", KeyPackage: []byte("key")})
	if err == nil {
		t.Fatal("expected expired invite registration to fail")
	}
}

func TestDeviceLinkRequiresApprovalBeforeSession(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)

	link, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute)
	if err != nil {
		t.Fatalf("create device link: %v", err)
	}
	claimToken, claimTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("claim token: %v", err)
	}
	claimed, err := store.ClaimDeviceLink(ctx, link.Code, "Tablet", []byte("tablet-key-package"), []byte("tablet-signing-key"), claimTokenHash)
	if err != nil {
		t.Fatalf("claim device link: %v", err)
	}
	if claimed.State != domain.DeviceLinkClaimed || claimed.VerificationCode != link.VerificationCode {
		t.Fatalf("unexpected claimed link: %#v", claimed)
	}
	_, sessionTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("session token: %v", err)
	}
	if _, err := store.ConsumeApprovedDeviceLink(ctx, link.ID, auth.HashToken(claimToken), sessionTokenHash, time.Now().UTC().Add(time.Hour)); !errors.Is(err, ErrDeviceLinkNotReady) {
		t.Fatalf("pre-approval consume err=%v want %v", err, ErrDeviceLinkNotReady)
	}
	if _, _, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, "000000"); !errors.Is(err, ErrDeviceLinkVerificationFailed) {
		t.Fatalf("wrong verification code err=%v want %v", err, ErrDeviceLinkVerificationFailed)
	}
	approved, device, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, link.VerificationCode)
	if err != nil {
		t.Fatalf("approve device link: %v", err)
	}
	if approved.State != domain.DeviceLinkApproved || device.AccountID != owner.Account.ID || device.Name != "Tablet" {
		t.Fatalf("unexpected approved device link: %#v %#v", approved, device)
	}
	if _, err := store.ConsumeApprovedDeviceLink(ctx, link.ID, auth.HashToken("wrong-claim-token"), sessionTokenHash, time.Now().UTC().Add(time.Hour)); !errors.Is(err, ErrDeviceLinkInvalid) {
		t.Fatalf("wrong claim token err=%v want %v", err, ErrDeviceLinkInvalid)
	}
	linked, err := store.ConsumeApprovedDeviceLink(ctx, link.ID, auth.HashToken(claimToken), sessionTokenHash, time.Now().UTC().Add(time.Hour))
	if err != nil {
		t.Fatalf("consume approved device link: %v", err)
	}
	if linked.Account.ID != owner.Account.ID || linked.Device.ID != device.ID {
		t.Fatalf("unexpected linked account/device: %#v", linked)
	}
	principal, err := store.PrincipalByTokenHash(ctx, sessionTokenHash)
	if err != nil {
		t.Fatalf("principal by linked token: %v", err)
	}
	if principal.AccountID != owner.Account.ID || principal.DeviceID != device.ID {
		t.Fatalf("unexpected linked principal: %#v", principal)
	}
	secondToken, secondTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("second session token: %v", err)
	}
	if _, err := store.ConsumeApprovedDeviceLink(ctx, link.ID, auth.HashToken(claimToken), secondTokenHash, time.Now().UTC().Add(time.Hour)); !errors.Is(err, ErrDeviceLinkInvalid) {
		t.Fatalf("second consume with token %q err=%v want %v", secondToken, err, ErrDeviceLinkInvalid)
	}
}

func TestMigrateRejectsEditedAppliedMigration(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	cfg := config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
	}
	store, err := Open(ctx, cfg)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()

	initial := fstest.MapFS{
		"0001_init.sql": {Data: []byte(`CREATE TABLE migrated_thing (id TEXT PRIMARY KEY);`)},
	}
	if err := store.Migrate(ctx, initial); err != nil {
		t.Fatalf("initial migrate: %v", err)
	}
	if err := store.Migrate(ctx, initial); err != nil {
		t.Fatalf("repeat migrate: %v", err)
	}

	edited := fstest.MapFS{
		"0001_init.sql": {Data: []byte(`CREATE TABLE migrated_thing (id TEXT PRIMARY KEY, name TEXT);`)},
	}
	err = store.Migrate(ctx, edited)
	if err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("edited migration err=%v want checksum mismatch", err)
	}
}

func newTestStore(t *testing.T, ctx context.Context) (*Store, config.Config) {
	t.Helper()
	dir := t.TempDir()
	cfg := config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
	}
	store, err := Open(ctx, cfg)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return store, cfg
}

func createTestOwner(t *testing.T, ctx context.Context, store *Store) AccountDevice {
	t.Helper()
	hash, err := auth.HashPassword("owner-password-123")
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	owner, err := store.CreateOwner(ctx, CreateOwnerInput{
		InstanceName: "Test Messenger",
		Username:     "Owner",
		PasswordHash: hash,
		DeviceName:   "Owner phone",
		KeyPackage:   []byte("owner-key-package"),
	})
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	return owner
}

func registerTestMember(t *testing.T, ctx context.Context, store *Store, inviteCode, username string) AccountDevice {
	t.Helper()
	hash, err := auth.HashPassword("member-password-123")
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	member, err := store.RegisterWithInvite(ctx, RegisterInput{
		InviteCode:   inviteCode,
		Username:     username,
		PasswordHash: hash,
		DeviceName:   username + " phone",
		KeyPackage:   []byte(username + "-key-package"),
	})
	if err != nil {
		t.Fatalf("register member %s: %v", username, err)
	}
	return member
}

func runtimeSentinel(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return "PLAINTEXT_SENTINEL_" + hex.EncodeToString(b[:])
}
