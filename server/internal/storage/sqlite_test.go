package storage

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
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
	memberReservation, err := store.ReserveRegistrationEnrollment(ctx, invite.Code)
	if err != nil {
		t.Fatalf("reserve member enrollment: %v", err)
	}
	member, err := store.RegisterWithInvite(ctx, RegisterInput{
		EnrollmentReservationID: memberReservation.ID,
		InviteCode:              invite.Code,
		Username:                "Member",
		PasswordHash:            memberHash,
		DeviceName:              "Member phone",
		KeyPackage:              []byte("member-key-package"),
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
	if _, err := store.CreatePushSubscription(ctx, member.Account.ID, member.Device.ID, "fcm", strings.Repeat("a", 32), "", ""); err != nil {
		t.Fatalf("create push subscription: %v", err)
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
		Ciphertext:      []byte("ciphertext bytes only"),
		CryptoProtocol:  "mls-openmls-todo",
	})
	if err != nil {
		t.Fatalf("duplicate save: %v", err)
	}
	if !duplicate || msg2.ID != msg.ID {
		t.Fatalf("expected idempotent duplicate, got duplicate=%v id=%s want=%s", duplicate, msg2.ID, msg.ID)
	}
	if _, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID: conversation.ID, SenderAccountID: owner.Account.ID,
		SenderDeviceID: owner.Device.ID, IdempotencyKey: "send-1",
		Ciphertext: []byte("different ciphertext"), CryptoProtocol: "mls-openmls-todo",
	}); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("mismatched idempotency err=%v want %v", err, ErrIdempotencyConflict)
	}
	messages, err := store.ListMessages(ctx, conversation.ID, member.Account.ID, ListMessagesOptions{Limit: 10})
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(messages) != 1 || !bytes.Equal(messages[0].Ciphertext, []byte("ciphertext bytes only")) {
		t.Fatalf("unexpected messages: %#v", messages)
	}
	versioned, duplicate, eventID, recipients, err := store.SaveMessageEnvelopeWithSyncEventAndRecipients(
		ctx, domain.MessageEnvelope{
			ConversationID:  conversation.ID,
			SenderAccountID: owner.Account.ID,
			SenderDeviceID:  owner.Device.ID,
			IdempotencyKey:  "sync-send-1",
			Ciphertext:      []byte("versioned ciphertext"),
			CryptoProtocol:  "mls-openmls-todo",
		})
	if err != nil || duplicate || versioned.ID == "" || eventID == 0 {
		t.Fatalf("versioned message event: id=%s duplicate=%v event=%d err=%v", versioned.ID, duplicate, eventID, err)
	}
	recipientSet := map[string]bool{}
	for _, recipient := range recipients {
		recipientSet[recipient] = true
	}
	if len(recipients) != 2 || !recipientSet[member.Account.ID] || !recipientSet[owner.Account.ID] {
		t.Fatalf("unexpected transactional recipients: %#v", recipients)
	}
	var queued int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM push_wake_jobs WHERE sync_event_id = ?`, eventID).Scan(&queued); err != nil {
		t.Fatalf("count wake jobs: %v", err)
	}
	if queued != 1 {
		t.Fatalf("wake job count=%d want 1", queued)
	}
	claimedAt := time.Now().UTC()
	wakeJobs, abandoned, err := store.ClaimPushWakeJobs(ctx, "fcm", 10, claimedAt, time.Minute)
	if err != nil || abandoned != 0 || len(wakeJobs) != 1 {
		t.Fatalf("claim wake jobs: jobs=%d abandoned=%d err=%v", len(wakeJobs), abandoned, err)
	}
	if wakeJobs[0].EventID != eventID || wakeJobs[0].RecipientAccountID != member.Account.ID || wakeJobs[0].Endpoint != strings.Repeat("a", 32) || wakeJobs[0].Attempts != 1 {
		t.Fatalf("unexpected claimed wake job: %#v", wakeJobs[0])
	}
	wakeJobs, _, err = store.ClaimPushWakeJobs(ctx, "fcm", 10, claimedAt.Add(2*time.Minute), time.Minute)
	if err != nil || len(wakeJobs) != 1 || wakeJobs[0].Attempts != 2 {
		t.Fatalf("reclaim wake job: jobs=%d err=%v", len(wakeJobs), err)
	}
	if err := store.RetryPushWakeJob(ctx, wakeJobs[0], time.Now().UTC().Add(-time.Second), time.Now().UTC()); err != nil {
		t.Fatalf("retry wake job: %v", err)
	}
	wakeJobs, _, err = store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now().UTC(), time.Minute)
	if err != nil || len(wakeJobs) != 1 || wakeJobs[0].Attempts != 3 {
		t.Fatalf("retry wake job: jobs=%d err=%v", len(wakeJobs), err)
	}
	oldWakeJob := wakeJobs[0]
	if _, err := store.db.ExecContext(ctx, `UPDATE push_subscriptions SET endpoint = ? WHERE id = ?`, strings.Repeat("b", 32), oldWakeJob.SubscriptionID); err != nil {
		t.Fatalf("rotate push subscription: %v", err)
	}
	if err := store.RetirePushWakeSubscription(ctx, oldWakeJob); err != nil {
		t.Fatalf("retire stale wake subscription: %v", err)
	}
	var disabledAt sql.NullString
	if err := store.db.QueryRowContext(ctx, `SELECT disabled_at FROM push_subscriptions WHERE id = ?`, oldWakeJob.SubscriptionID).Scan(&disabledAt); err != nil {
		t.Fatalf("read rotated subscription: %v", err)
	}
	if disabledAt.Valid {
		t.Fatal("stale provider result disabled rotated subscription")
	}
	wakeJobs, _, err = store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now().UTC().Add(time.Second), time.Minute)
	if err != nil || len(wakeJobs) != 1 || wakeJobs[0].Attempts != 4 || wakeJobs[0].Endpoint != strings.Repeat("b", 32) {
		t.Fatalf("reclaim rotated wake job: jobs=%d err=%v job=%#v", len(wakeJobs), err, wakeJobs)
	}
	if err := store.CompletePushWakeJob(ctx, oldWakeJob); err != nil {
		t.Fatalf("complete stale wake job: %v", err)
	}
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM push_wake_jobs WHERE sync_event_id = ?`, eventID).Scan(&queued); err != nil || queued != 1 {
		t.Fatalf("stale wake completion changed queue: queued=%d err=%v", queued, err)
	}
	if err := store.CompletePushWakeJob(ctx, wakeJobs[0]); err != nil {
		t.Fatalf("complete wake job: %v", err)
	}
	var eventPayload string
	if err := store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, eventID).Scan(&eventPayload); err != nil {
		t.Fatalf("read versioned event: %v", err)
	}
	if !bytes.Contains([]byte(eventPayload), []byte(`"envelope"`)) ||
		!bytes.Contains([]byte(eventPayload), []byte(`"ciphertext"`)) {
		t.Fatalf("versioned event omitted immutable envelope: %s", eventPayload)
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

func TestEverySQLiteConnectionEnforcesSafetyPragmas(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	connections := make([]*sql.Conn, 0, 4)
	defer func() {
		for _, connection := range connections {
			_ = connection.Close()
		}
	}()
	for i := 0; i < 4; i++ {
		connection, err := store.db.reader.Conn(ctx)
		if err != nil {
			t.Fatalf("reader connection %d: %v", i, err)
		}
		connections = append(connections, connection)
		var foreignKeys, busyTimeout int
		if err := connection.QueryRowContext(ctx, `PRAGMA foreign_keys`).Scan(&foreignKeys); err != nil {
			t.Fatalf("foreign_keys connection %d: %v", i, err)
		}
		if err := connection.QueryRowContext(ctx, `PRAGMA busy_timeout`).Scan(&busyTimeout); err != nil {
			t.Fatalf("busy_timeout connection %d: %v", i, err)
		}
		if foreignKeys != 1 || busyTimeout != 5000 {
			t.Fatalf("connection %d pragmas foreign_keys=%d busy_timeout=%d", i, foreignKeys, busyTimeout)
		}
	}
}

func TestRecoveryCapabilityExpiresAndConsumesAfterResumableTransfer(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	firstToken := bytes.Repeat([]byte{1}, 32)
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "recovery-blob", strings.Repeat("a", 64), 6, json.RawMessage(`{"state_counter":1}`), firstToken); err != nil {
		t.Fatalf("create backup: %v", err)
	}
	transfer, err := store.BeginRecoveryTransfer(ctx, firstToken, 0)
	if err != nil {
		t.Fatalf("begin first transfer: %v", err)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, firstToken, 0); !errors.Is(err, ErrRecoveryBusy) {
		t.Fatalf("concurrent transfer err=%v want %v", err, ErrRecoveryBusy)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE backup_blobs SET recovery_lease_expires_at = ? WHERE recovery_lease_id = ?`, formatTime(time.Now().UTC().Add(-time.Minute)), transfer.LeaseID); err != nil {
		t.Fatalf("expire transfer lease: %v", err)
	}
	if err := store.CompleteRecoveryTransfer(ctx, transfer.LeaseID, transfer.StartOffset, 3, 6); !errors.Is(err, ErrRecoveryBusy) {
		t.Fatalf("stale completion err=%v want %v", err, ErrRecoveryBusy)
	}
	transfer, err = store.BeginRecoveryTransfer(ctx, firstToken, 0)
	if err != nil {
		t.Fatalf("take over expired transfer lease: %v", err)
	}
	if err := store.CompleteRecoveryTransfer(ctx, transfer.LeaseID, transfer.StartOffset, 3, 6); err != nil {
		t.Fatalf("complete interrupted transfer: %v", err)
	}
	transfer, err = store.BeginRecoveryTransfer(ctx, firstToken, 3)
	if err != nil {
		t.Fatalf("resume transfer: %v", err)
	}
	if err := store.CompleteRecoveryTransfer(ctx, transfer.LeaseID, transfer.StartOffset, 3, 3); err != nil {
		t.Fatalf("complete final transfer: %v", err)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, firstToken, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("replayed capability err=%v want %v", err, ErrNotFound)
	}

	secondToken := bytes.Repeat([]byte{2}, 32)
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "recovery-blob-2", strings.Repeat("b", 64), 1, json.RawMessage(`{"state_counter":2}`), secondToken); err != nil {
		t.Fatalf("create rotated backup: %v", err)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, firstToken, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("rotated capability err=%v want %v", err, ErrNotFound)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE backup_blobs SET recovery_expires_at = ? WHERE recovery_token_hash = ?`, formatTime(time.Now().UTC().Add(-time.Minute)), secondToken); err != nil {
		t.Fatalf("expire capability: %v", err)
	}
	if _, err := store.BeginRecoveryTransfer(ctx, secondToken, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired capability err=%v want %v", err, ErrNotFound)
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
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "backup_blob", strings.Repeat("a", 64), 64, json.RawMessage(`{"state_counter":1}`), make([]byte, 32)); err != nil {
		t.Fatalf("create backup blob: %v", err)
	}
	if _, err := store.CreatePushSubscription(ctx, owner.Account.ID, owner.Device.ID, "webpush", "https://push.example.test/owner", "owner-public-key", "owner-reusable-push-secret"); err != nil {
		t.Fatalf("create owner push subscription: %v", err)
	}
	export, err := store.ExportAccount(ctx, owner.Account.ID, ExportAccountOptions{})
	if err != nil {
		t.Fatalf("export account: %v", err)
	}
	if export.Account.ID != owner.Account.ID || len(export.Messages) != 1 {
		t.Fatalf("unexpected export: %#v", export)
	}
	if export.ManifestVersion != "v2" {
		t.Fatalf("export manifest=%q want v2", export.ManifestVersion)
	}
	exported, err := json.Marshal(export)
	if err != nil {
		t.Fatalf("marshal export: %v", err)
	}
	if bytes.Contains(exported, []byte("owner-reusable-push-secret")) ||
		bytes.Contains(exported, []byte(`"auth_secret"`)) {
		t.Fatalf("export contains a reusable push credential: %s", exported)
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
	enrollment, err := store.ReserveDeviceLinkEnrollment(ctx, link.Code)
	if err != nil {
		t.Fatalf("reserve device link enrollment: %v", err)
	}
	claimToken, claimTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("claim token: %v", err)
	}
	transcriptHash := bytes.Repeat([]byte{3}, 32)
	claimed, err := store.ClaimDeviceLink(ctx, link.Code, "Tablet", []byte("tablet-key-package"), bytes.Repeat([]byte{2}, 32), transcriptHash, claimTokenHash, auth.HashToken("tablet-device-secret"))
	if err != nil {
		t.Fatalf("claim device link: %v", err)
	}
	if claimed.State != domain.DeviceLinkClaimed || !bytes.Equal(claimed.TranscriptHash, transcriptHash) {
		t.Fatalf("unexpected claimed link: %#v", claimed)
	}
	_, sessionTokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("session token: %v", err)
	}
	if _, err := store.ConsumeApprovedDeviceLink(ctx, link.ID, auth.HashToken(claimToken), sessionTokenHash, time.Now().UTC().Add(time.Hour)); !errors.Is(err, ErrDeviceLinkNotReady) {
		t.Fatalf("pre-approval consume err=%v want %v", err, ErrDeviceLinkNotReady)
	}
	if _, _, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, bytes.Repeat([]byte{4}, 32)); !errors.Is(err, ErrDeviceLinkVerificationFailed) {
		t.Fatalf("wrong verification code err=%v want %v", err, ErrDeviceLinkVerificationFailed)
	}
	approved, device, err := store.ApproveDeviceLink(ctx, link.ID, owner.Account.ID, transcriptHash)
	if err != nil {
		t.Fatalf("approve device link: %v", err)
	}
	if approved.State != domain.DeviceLinkApproved || device.AccountID != owner.Account.ID || device.Name != "Tablet" || device.ID != enrollment.DeviceID {
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
	expired, err := store.CreateDeviceLink(ctx, owner.Account.ID, owner.Device.ID, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE device_links SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Minute)), expired.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReserveDeviceLinkEnrollment(ctx, expired.Code); !errors.Is(err, ErrDeviceLinkInvalid) {
		t.Fatalf("expired link enrollment err=%v want %v", err, ErrDeviceLinkInvalid)
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

func TestDMUniquenessAndGroupMemberLifecycle(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)

	register := func(username string) AccountDevice {
		invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
		if err != nil {
			t.Fatalf("create %s invite: %v", username, err)
		}
		return registerTestMember(t, ctx, store, invite.Code, username)
	}
	member := register("lifemember")
	outsider := register("lifeoutsider")
	removable := register("liferemovable")

	start := make(chan struct{})
	results := make(chan struct {
		conversation domain.Conversation
		err          error
	}, 2)
	var wg sync.WaitGroup
	for _, input := range []CreateConversationInput{
		{Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{member.Account.ID}},
		{Kind: "dm", CreatedBy: member.Account.ID, MemberAccountIDs: []string{owner.Account.ID}},
	} {
		wg.Add(1)
		go func(input CreateConversationInput) {
			defer wg.Done()
			<-start
			conversation, err := store.CreateConversation(ctx, input)
			results <- struct {
				conversation domain.Conversation
				err          error
			}{conversation: conversation, err: err}
		}(input)
	}
	close(start)
	wg.Wait()
	close(results)
	var dmID string
	for result := range results {
		if result.err != nil {
			t.Fatalf("concurrent DM create: %v", result.err)
		}
		if dmID == "" {
			dmID = result.conversation.ID
		} else if result.conversation.ID != dmID {
			t.Fatalf("duplicate DM ids: %s and %s", dmID, result.conversation.ID)
		}
	}
	retry, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "dm", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{member.Account.ID}})
	if err != nil || retry.ID != dmID {
		t.Fatalf("DM retry conversation=%#v err=%v want id=%s", retry, err, dmID)
	}
	var dmCount int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations WHERE kind = 'dm'`).Scan(&dmCount); err != nil || dmCount != 1 {
		t.Fatalf("DM count=%d err=%v want 1", dmCount, err)
	}
	if err := store.AddConversationMember(ctx, dmID, outsider.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("add third DM member err=%v want %v", err, ErrForbidden)
	}
	if _, err := store.ManageConversationMember(ctx, dmID, owner.Account.ID, outsider.Account.ID, domain.RoleMember); !errors.Is(err, ErrForbidden) {
		t.Fatalf("manage third DM member err=%v want %v", err, ErrForbidden)
	}

	group, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "group",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{member.Account.ID, removable.Account.ID},
	})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}
	members, err := store.ListConversationMembers(ctx, group.ID, owner.Account.ID)
	if err != nil || len(members) != 3 {
		t.Fatalf("authorized roster members=%#v err=%v", members, err)
	}
	// Co-members get usernames so the client can name people instead of
	// showing raw account IDs.
	for _, member := range members {
		if member.Username == "" {
			t.Fatalf("roster member %s has no username", member.AccountID)
		}
	}
	if members, err := store.ListConversationMembers(ctx, group.ID, outsider.Account.ID); !errors.Is(err, ErrNotMember) || len(members) != 0 {
		t.Fatalf("outsider roster members=%#v err=%v want no disclosure", members, err)
	}
	if _, err := store.RemoveConversationMember(ctx, group.ID, member.Account.ID, owner.Account.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("lower-rank removal err=%v want %v", err, ErrForbidden)
	}
	if _, err := store.RemoveConversationMember(ctx, group.ID, owner.Account.ID, owner.Account.ID); !errors.Is(err, ErrLastOwner) {
		t.Fatalf("last owner leave err=%v want %v", err, ErrLastOwner)
	}
	events, err := store.RemoveConversationMember(ctx, group.ID, owner.Account.ID, removable.Account.ID)
	if err != nil || events.RemainingMembersEventID <= 0 || events.RemovedMemberEventID <= 0 {
		t.Fatalf("authorized removal events=%#v err=%v", events, err)
	}
	if _, err := store.RemoveConversationMember(ctx, group.ID, owner.Account.ID, removable.Account.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removal retry err=%v want %v", err, ErrNotFound)
	}
	var payload string
	if err := store.db.QueryRowContext(ctx, `SELECT payload_json FROM sync_events WHERE id = ?`, events.RemovedMemberEventID).Scan(&payload); err != nil || !strings.Contains(payload, `"mls_coordination":"pending"`) {
		t.Fatalf("removal event payload=%s err=%v", payload, err)
	}
	if eventID, err := store.ManageConversationMember(ctx, group.ID, owner.Account.ID, member.Account.ID, domain.RoleOwner); err != nil || eventID <= 0 {
		t.Fatalf("promote second owner event_id=%d err=%v", eventID, err)
	}
	if _, err := store.RemoveConversationMember(ctx, group.ID, owner.Account.ID, owner.Account.ID); err != nil {
		t.Fatalf("owner leave after transfer: %v", err)
	}
	remaining, err := store.ListConversationMembers(ctx, group.ID, member.Account.ID)
	if err != nil || len(remaining) != 1 || remaining[0].AccountID != member.Account.ID || remaining[0].Role != domain.RoleOwner {
		t.Fatalf("remaining roster=%#v err=%v", remaining, err)
	}
}

func TestClaimConversationKeyPackagesUsesMigratedMembershipsOnce(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()

	owner := createTestOwner(t, ctx, store)
	memberInvite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create member invite: %v", err)
	}
	member := registerTestMember(t, ctx, store, memberInvite.Code, "member")
	outsiderInvite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create outsider invite: %v", err)
	}
	outsider := registerTestMember(t, ctx, store, outsiderInvite.Code, "outsider")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "group",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{member.Account.ID},
	})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	packages, err := store.ClaimConversationKeyPackages(ctx, conversation.ID, outsider.Account.ID, outsider.Device.ID)
	if !errors.Is(err, ErrNotMember) || len(packages) != 0 {
		t.Fatalf("non-member claim packages=%#v err=%v want no packages and %v", packages, err, ErrNotMember)
	}

	packages, err = store.ClaimConversationKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID)
	if err != nil {
		t.Fatalf("member claim from migrated database: %v", err)
	}
	if len(packages) != 1 {
		t.Fatalf("claimed %d packages want 1: %#v", len(packages), packages)
	}
	if packages[0].DeviceID != member.Device.ID || !bytes.Equal(packages[0].KeyPackage, member.Device.KeyPackage) {
		t.Fatalf("claimed wrong device package: %#v", packages[0])
	}
	if packages[0].DeviceID == owner.Device.ID {
		t.Fatal("requester device package must be excluded")
	}

	packages, err = store.ClaimConversationKeyPackages(ctx, conversation.ID, owner.Account.ID, owner.Device.ID)
	if !errors.Is(err, ErrKeyPackageUnavailable) || len(packages) != 0 {
		t.Fatalf("repeated claim packages=%#v err=%v want no packages and %v", packages, err, ErrKeyPackageUnavailable)
	}
	var ownerClaims int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM device_key_packages WHERE device_id = ? AND claimed_at IS NOT NULL`, owner.Device.ID).Scan(&ownerClaims); err != nil {
		t.Fatalf("count requester claims: %v", err)
	}
	if ownerClaims != 0 {
		t.Fatalf("requester device had %d packages consumed", ownerClaims)
	}
}

func TestSyncEventFailureRollsBackDurableMutations(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()

	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "atomicmember")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "group",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{member.Account.ID},
	})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	message, _, err := store.SaveMessageEnvelope(ctx, domain.MessageEnvelope{
		ConversationID:  conversation.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "atomic-event-message",
		Ciphertext:      []byte("original ciphertext"),
		CryptoProtocol:  "mls-openmls-todo",
	})
	if err != nil {
		t.Fatalf("save message: %v", err)
	}
	if err := store.CreateReaction(ctx, message.ID, member.Account.ID, []byte("original reaction")); err != nil {
		t.Fatalf("create initial reaction: %v", err)
	}
	callConversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "dm",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{member.Account.ID},
	})
	if err != nil {
		t.Fatalf("create call DM: %v", err)
	}
	call, err := store.CreateCallSession(ctx, callConversation.ID, owner.Account.ID, nil)
	if err != nil {
		t.Fatalf("create initial call: %v", err)
	}
	var initialEventCount int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events`).Scan(&initialEventCount); err != nil {
		t.Fatalf("count initial events: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `CREATE TRIGGER fail_sync_event BEFORE INSERT ON sync_events BEGIN SELECT RAISE(FAIL, 'forced sync event failure'); END`); err != nil {
		t.Fatalf("create failure trigger: %v", err)
	}

	if _, eventID, err := store.UpdateMessageEnvelopeWithSyncEvent(ctx, message.ID, owner.Account.ID, []byte("edited ciphertext"), "mls-openmls-todo", nil); err == nil || eventID != 0 {
		t.Fatalf("update err=%v event_id=%d want failure and zero", err, eventID)
	}
	if _, eventID, err := store.DeleteMessageEnvelopeWithSyncEvent(ctx, message.ID, owner.Account.ID, []byte("delete marker"), "mls-openmls-todo", nil); err == nil || eventID != 0 {
		t.Fatalf("delete err=%v event_id=%d want failure and zero", err, eventID)
	}
	storedMessage, err := store.MessageByID(ctx, message.ID)
	if err != nil || !bytes.Equal(storedMessage.Ciphertext, message.Ciphertext) || storedMessage.DeletedAt != nil {
		t.Fatalf("message mutation was not rolled back: %#v err=%v", storedMessage, err)
	}

	if _, eventID, err := store.CreateReactionWithSyncEvent(ctx, message.ID, member.Account.ID, []byte("changed reaction")); err == nil || eventID != 0 {
		t.Fatalf("reaction create err=%v event_id=%d want failure and zero", err, eventID)
	}
	if _, eventID, err := store.DeleteReactionWithSyncEvent(ctx, message.ID, member.Account.ID); err == nil || eventID != 0 {
		t.Fatalf("reaction delete err=%v event_id=%d want failure and zero", err, eventID)
	}
	var reactionCiphertext []byte
	if err := store.db.QueryRowContext(ctx, `SELECT reaction_ciphertext FROM reactions WHERE message_id = ? AND account_id = ?`, message.ID, member.Account.ID).Scan(&reactionCiphertext); err != nil || !bytes.Equal(reactionCiphertext, []byte("original reaction")) {
		t.Fatalf("reaction mutation was not rolled back: %q err=%v", reactionCiphertext, err)
	}

	if eventID, err := store.MarkReadWithSyncEvent(ctx, conversation.ID, member.Account.ID, message.ID); err == nil || eventID != 0 {
		t.Fatalf("read receipt err=%v event_id=%d want failure and zero", err, eventID)
	}
	var receiptCount int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM read_receipts WHERE account_id = ? AND conversation_id = ?`, member.Account.ID, conversation.ID).Scan(&receiptCount); err != nil || receiptCount != 0 {
		t.Fatalf("read receipt was not rolled back: count=%d err=%v", receiptCount, err)
	}

	retention := int64(3600)
	if _, eventID, err := store.UpdateConversationRetentionWithSyncEvent(ctx, conversation.ID, owner.Account.ID, &retention); err == nil || eventID != 0 {
		t.Fatalf("retention err=%v event_id=%d want failure and zero", err, eventID)
	}
	storedConversation, err := store.ConversationByID(ctx, conversation.ID)
	if err != nil || storedConversation.RetentionSeconds != nil {
		t.Fatalf("retention mutation was not rolled back: %#v err=%v", storedConversation, err)
	}

	if _, eventID, err := store.CreateCallSessionWithSyncEvent(ctx, callConversation.ID, owner.Account.ID, nil); err == nil || eventID != 0 {
		t.Fatalf("call create err=%v event_id=%d want failure and zero", err, eventID)
	}
	if _, eventID, err := store.TransitionCallSessionWithSyncEvent(ctx, call.ID, owner.Account.ID, 1, "ended", nil); err == nil || eventID != 0 {
		t.Fatalf("call transition err=%v event_id=%d want failure and zero", err, eventID)
	}
	var callCount int
	var callState string
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*), MIN(state) FROM call_sessions WHERE conversation_id = ?`, callConversation.ID).Scan(&callCount, &callState); err != nil || callCount != 1 || callState != "ringing" {
		t.Fatalf("call mutation was not rolled back: count=%d state=%q err=%v", callCount, callState, err)
	}

	if eventID, err := store.RevokeDeviceWithSyncEvent(ctx, member.Account.ID, member.Device.ID); err == nil || eventID != 0 {
		t.Fatalf("device revoke err=%v event_id=%d want failure and zero", err, eventID)
	}
	var revokedAt sql.NullString
	if err := store.db.QueryRowContext(ctx, `SELECT revoked_at FROM devices WHERE id = ?`, member.Device.ID).Scan(&revokedAt); err != nil || revokedAt.Valid {
		t.Fatalf("device revoke was not rolled back: revoked_at=%v err=%v", revokedAt, err)
	}

	var finalEventCount int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sync_events`).Scan(&finalEventCount); err != nil || finalEventCount != initialEventCount {
		t.Fatalf("failed mutations changed event count: initial=%d final=%d err=%v", initialEventCount, finalEventCount, err)
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

func TestListConversationsPageNamesDMPeerPerViewer(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)

	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	peer := registerTestMember(t, ctx, store, invite.Code, "dmpeer")

	dm, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "dm",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{peer.Account.ID},
	})
	if err != nil {
		t.Fatalf("create dm: %v", err)
	}
	group, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "group",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{peer.Account.ID},
	})
	if err != nil {
		t.Fatalf("create group: %v", err)
	}

	find := func(accountID, conversationID string) domain.Conversation {
		t.Helper()
		page, err := store.ListConversationsPage(ctx, accountID, 100, "")
		if err != nil {
			t.Fatalf("list conversations for %s: %v", accountID, err)
		}
		for _, conversation := range page {
			if conversation.ID == conversationID {
				return conversation
			}
		}
		t.Fatalf("conversation %s not listed for %s", conversationID, accountID)
		return domain.Conversation{}
	}

	// Each side sees the other, never themselves.
	ownerView := find(owner.Account.ID, dm.ID)
	if ownerView.PeerAccountID != peer.Account.ID || ownerView.PeerUsername != "dmpeer" {
		t.Fatalf("owner DM peer=%q/%q want %q/dmpeer", ownerView.PeerAccountID, ownerView.PeerUsername, peer.Account.ID)
	}
	peerView := find(peer.Account.ID, dm.ID)
	if peerView.PeerAccountID != owner.Account.ID || peerView.PeerUsername == "" {
		t.Fatalf("peer DM peer=%q/%q want %q with a username", peerView.PeerAccountID, peerView.PeerUsername, owner.Account.ID)
	}

	// Groups have no single counterpart; claiming one would mislabel the row.
	groupView := find(owner.Account.ID, group.ID)
	if groupView.PeerAccountID != "" || groupView.PeerUsername != "" {
		t.Fatalf("group peer=%q/%q want empty", groupView.PeerAccountID, groupView.PeerUsername)
	}
}

func createTestOwner(t *testing.T, ctx context.Context, store *Store) AccountDevice {
	t.Helper()
	reservation, err := store.ReserveOwnerEnrollment(ctx)
	if err != nil {
		t.Fatalf("reserve owner enrollment: %v", err)
	}
	hash, err := auth.HashPassword("owner-password-123")
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	owner, err := store.CreateOwner(ctx, CreateOwnerInput{
		EnrollmentReservationID: reservation.ID,
		InstanceName:            "Test Messenger",
		Username:                "Owner",
		PasswordHash:            hash,
		DeviceName:              "Owner phone",
		KeyPackage:              []byte("owner-key-package"),
		SigningKey:              bytes.Repeat([]byte{1}, 32),
	})
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	return owner
}

func registerTestMember(t *testing.T, ctx context.Context, store *Store, inviteCode, username string) AccountDevice {
	t.Helper()
	reservation, err := store.ReserveRegistrationEnrollment(ctx, inviteCode)
	if err != nil {
		t.Fatalf("reserve member enrollment: %v", err)
	}
	hash, err := auth.HashPassword("member-password-123")
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	member, err := store.RegisterWithInvite(ctx, RegisterInput{
		EnrollmentReservationID: reservation.ID,
		InviteCode:              inviteCode,
		Username:                username,
		PasswordHash:            hash,
		DeviceName:              username + " phone",
		KeyPackage:              []byte(username + "-key-package"),
	})
	if err != nil {
		t.Fatalf("register member %s: %v", username, err)
	}
	return member
}

func TestSessionIdleTouchKeepsAbsoluteLifetimeBounded(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	_, tokenHash, err := auth.NewToken()
	if err != nil {
		t.Fatalf("session token: %v", err)
	}
	if err := store.CreateSession(ctx, tokenHash, owner.Account.ID, owner.Device.ID, time.Now().UTC().Add(SessionIdleLifetime)); err != nil {
		t.Fatalf("create session: %v", err)
	}
	var absoluteBefore string
	if err := store.db.QueryRowContext(ctx, `SELECT absolute_expires_at FROM sessions WHERE token_hash = ?`, tokenHash).Scan(&absoluteBefore); err != nil {
		t.Fatalf("read absolute expiry: %v", err)
	}
	if err := store.TouchSession(ctx, tokenHash); err != nil {
		t.Fatalf("touch session: %v", err)
	}
	var absoluteAfter string
	if err := store.db.QueryRowContext(ctx, `SELECT absolute_expires_at FROM sessions WHERE token_hash = ?`, tokenHash).Scan(&absoluteAfter); err != nil {
		t.Fatalf("read touched absolute expiry: %v", err)
	}
	if absoluteBefore != absoluteAfter {
		t.Fatalf("absolute expiry moved from %q to %q", absoluteBefore, absoluteAfter)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE sessions SET last_used_at = ? WHERE token_hash = ?`, formatTime(time.Now().UTC().Add(-SessionIdleLifetime-time.Second)), tokenHash); err != nil {
		t.Fatalf("age session: %v", err)
	}
	if _, err := store.PrincipalByTokenHash(ctx, tokenHash); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("idle-expired session err=%v want %v", err, ErrUnauthorized)
	}
}

func runtimeSentinel(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return "PLAINTEXT_SENTINEL_" + hex.EncodeToString(b[:])
}
