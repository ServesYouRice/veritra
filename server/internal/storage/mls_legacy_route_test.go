package storage

import (
	"context"
	"errors"
	"testing"
	"time"
)

// The single-message MLS route (POST /conversations/{id}/mls/messages) only
// serves groups that are already legacy (pre-I51: MLS history, no roster).
// It must never write a conversation's first MLS message: that would make
// the conversation legacy and refuse its creator's first commit bundle
// (ErrMLSGroupLegacy) while the junk message is retained (docs/crypto.md,
// "K0 R2 review, legacy-group revocation coordinator").

func legacyRouteFixture(t *testing.T, ctx context.Context) (*Store, AccountDevice, AccountDevice, string) {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	bob := registerTestMember(t, ctx, store, invite.Code, "bob")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID,
		MemberAccountIDs: []string{bob.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	return store, owner, bob, conversation.ID
}

// A member cannot make a fresh conversation legacy: neither a commit nor a
// Welcome nor a revocation commit is stored, no legacy mark or evidence is
// left behind, and the creator's first bundle still records the group.
func TestLegacyMLSRouteRefusesAConversationsFirstMessage(t *testing.T) {
	ctx := context.Background()
	store, owner, bob, conversationID := legacyRouteFixture(t, ctx)

	for name, input := range map[string]CreateMLSMessageInput{
		"commit":  {Kind: "commit", Payload: []byte("junk-commit"), IdempotencyKey: "junk-commit"},
		"welcome": {Kind: "welcome", RecipientDeviceID: owner.Device.ID, Payload: []byte("junk-welcome"), IdempotencyKey: "junk-welcome"},
	} {
		input.ConversationID, input.SenderAccountID, input.SenderDeviceID = conversationID, bob.Account.ID, bob.Device.ID
		if _, _, err := store.CreateMLSMessage(ctx, input); !errors.Is(err, ErrMLSBundleRequired) {
			t.Fatalf("%s as a conversation's first MLS message: err = %v, want %v", name, err, ErrMLSBundleRequired)
		}
		// A retry with the same key is refused the same way: nothing was stored.
		if _, _, err := store.CreateMLSMessage(ctx, input); !errors.Is(err, ErrMLSBundleRequired) {
			t.Fatalf("%s retried: err = %v, want %v", name, err, ErrMLSBundleRequired)
		}
	}
	for table, query := range map[string]string{
		"messages": `SELECT COUNT(*) FROM conversation_mls_messages WHERE conversation_id = ?`,
		"marks":    `SELECT COUNT(*) FROM mls_legacy_marks WHERE conversation_id = ?`,
		"evidence": `SELECT COUNT(*) FROM mls_legacy_leaf_evidence WHERE conversation_id = ?`,
		"events":   `SELECT COUNT(*) FROM sync_events WHERE conversation_id = ? AND event_type = 'mls.message.created'`,
	} {
		if n := testRowCount(t, ctx, store, query, conversationID); n != 0 {
			t.Fatalf("%s rows after the refused messages = %d, want 0", table, n)
		}
	}

	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversationID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis", Commit: []byte("commit-0"), Welcome: []byte("welcome-0"),
		Added: []MLSDeviceRef{{AccountID: bob.Account.ID, DeviceID: bob.Device.ID}},
	}); err != nil {
		t.Fatalf("creator's first bundle after the refused junk: %v", err)
	}
	// Once rostered, the route keeps refusing (card I51).
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversationID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Kind: "commit", Payload: []byte("late"), IdempotencyKey: "late",
	}); !errors.Is(err, ErrMLSBundleRequired) {
		t.Fatalf("legacy route into a rostered group: err = %v", err)
	}
}

// An older app draining its queued non-bundle items into a group that is
// already legacy keeps working: commits and Welcomes from any member device
// are stored, and the 0096 evidence rules hold for them.
func TestLegacyMLSRouteStillServesALegacyGroup(t *testing.T) {
	ctx := context.Background()
	store, owner, bob, conversationID := legacyRouteFixture(t, ctx)
	seedLegacyMLSMessage(t, store, CreateMLSMessageInput{
		ConversationID: conversationID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Kind: "commit", Payload: []byte("legacy-0"), IdempotencyKey: "legacy-0",
	})
	time.Sleep(2 * time.Millisecond)
	const tablet = "dev-z-bob-tablet"
	addTestDevice(t, ctx, store, bob.Account.ID, tablet)

	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversationID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Kind: "commit", Payload: []byte("queued-commit"), IdempotencyKey: "queued-commit",
	}); err != nil {
		t.Fatalf("queued commit into a legacy group: %v", err)
	}
	welcome := CreateMLSMessageInput{
		ConversationID: conversationID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		RecipientDeviceID: tablet, Kind: "welcome", Payload: []byte("queued-welcome"), IdempotencyKey: "queued-welcome",
	}
	first, duplicate, err := store.CreateMLSMessage(ctx, welcome)
	if err != nil || duplicate {
		t.Fatalf("queued Welcome into a legacy group: duplicate=%v err=%v", duplicate, err)
	}
	if again, duplicate, err := store.CreateMLSMessage(ctx, welcome); err != nil || !duplicate || again.ID != first.ID {
		t.Fatalf("retried Welcome: duplicate=%v err=%v", duplicate, err)
	}
	// Bob's phone existed at the group's first message, so its Welcome gives
	// the tablet evidence (migration 0096).
	if !legacyEvidence(t, ctx, store, conversationID, tablet) {
		t.Fatal("tablet welcomed by a device with evidence has none")
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM conversation_mls_messages WHERE conversation_id = ?`, conversationID); n != 3 {
		t.Fatalf("legacy messages = %d, want 3", n)
	}
}

// Both routes read one rule. A legacy group whose every message retention
// pruned is no longer legacy to either: the single-message route refuses
// (so no member can make it legacy again), and its creator may record a new
// group.
func TestLegacyMLSRouteAndBundleRouteAgreeAfterAFullPrune(t *testing.T) {
	ctx := context.Background()
	store, owner, bob, conversationID := legacyRouteFixture(t, ctx)
	seedLegacyMLSMessage(t, store, CreateMLSMessageInput{
		ConversationID: conversationID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Kind: "commit", Payload: []byte("legacy-0"), IdempotencyKey: "legacy-0",
	})
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversationID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "early-genesis",
	}); !errors.Is(err, ErrMLSGroupLegacy) {
		t.Fatalf("genesis while legacy history is retained: err = %v, want %v", err, ErrMLSGroupLegacy)
	}
	time.Sleep(2 * time.Millisecond)
	if _, err := store.PruneSyncEvents(ctx, time.Now().UTC().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if n := testRowCount(t, ctx, store, `SELECT COUNT(*) FROM conversation_mls_messages WHERE conversation_id = ?`, conversationID); n != 0 {
		t.Fatalf("messages after the prune = %d, want 0", n)
	}
	if _, _, err := store.CreateMLSMessage(ctx, CreateMLSMessageInput{
		ConversationID: conversationID, SenderAccountID: bob.Account.ID, SenderDeviceID: bob.Device.ID,
		Kind: "commit", Payload: []byte("junk"), IdempotencyKey: "junk",
	}); !errors.Is(err, ErrMLSBundleRequired) {
		t.Fatalf("legacy route after every legacy message was pruned: err = %v, want %v", err, ErrMLSBundleRequired)
	}
	if _, err := store.CreateMLSCommitBundle(ctx, MLSCommitBundleInput{
		ConversationID: conversationID, SenderAccountID: owner.Account.ID, SenderDeviceID: owner.Device.ID,
		Epoch: 0, IdempotencyKey: "genesis",
	}); err != nil {
		t.Fatalf("genesis after the prune: %v", err)
	}
}
