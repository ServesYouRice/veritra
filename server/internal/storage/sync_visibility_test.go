package storage

import (
	"context"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

type syncVisibilityFixture struct {
	store                      *Store
	blocker, sender, bystander AccountDevice
	conversation               domain.Conversation
}

// newSyncVisibilityFixture is a group of a blocker, a sender the blocker has
// blocked, and a bystander who blocked nobody.
func newSyncVisibilityFixture(t *testing.T, ctx context.Context) *syncVisibilityFixture {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	sender := registerTestMember(t, ctx, store, invite.Code, "sender")
	bystander := registerTestMember(t, ctx, store, invite.Code, "bystander")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID, MemberAccountIDs: []string{sender.Account.ID, bystander.Account.ID}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.BlockAccount(ctx, owner.Account.ID, sender.Account.ID); err != nil {
		t.Fatal(err)
	}
	return &syncVisibilityFixture{store: store, blocker: owner, sender: sender, bystander: bystander, conversation: conversation}
}

// send saves a message from the sender and returns it with its sync event id.
func (f *syncVisibilityFixture) send(t *testing.T, ctx context.Context, key string, expiresAt *time.Time) (domain.MessageEnvelope, int64) {
	t.Helper()
	saved, _, eventID, err := f.store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{
		ConversationID: f.conversation.ID, SenderAccountID: f.sender.Account.ID, SenderDeviceID: f.sender.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("ciphertext-" + key), CryptoProtocol: "mls-openmls-todo", ExpiresAt: expiresAt,
	})
	if err != nil || eventID == 0 {
		t.Fatalf("send %s: event %d, err = %v", key, eventID, err)
	}
	return saved, eventID
}

func (f *syncVisibilityFixture) expire(t *testing.T, ctx context.Context, messageID string) {
	t.Helper()
	if _, err := f.store.db.ExecContext(ctx, `UPDATE message_envelopes SET expires_at = ? WHERE id = ?`, formatTime(time.Now().UTC().Add(-time.Minute)), messageID); err != nil {
		t.Fatal(err)
	}
}

func (f *syncVisibilityFixture) eventIDs(t *testing.T, ctx context.Context, account AccountDevice) map[int64]bool {
	t.Helper()
	events, err := f.store.ListSyncEvents(ctx, account.Account.ID, account.Device.ID, 0, 200)
	if err != nil {
		t.Fatal(err)
	}
	ids := make(map[int64]bool, len(events))
	for _, event := range events {
		ids[event.ID] = true
	}
	return ids
}

// A block hides the blocked sender's message events. That has to hold after
// the envelope row is hard-deleted, when the sender can no longer be looked up
// in message_envelopes.
func TestSyncBlockFilterHoldsAfterEnvelopeIsPruned(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	soon := time.Now().UTC().Add(time.Hour)
	expiring, expiringEvent := f.send(t, ctx, "expiring", &soon)
	_, keptEvent := f.send(t, ctx, "kept", nil)
	if seen := f.eventIDs(t, ctx, f.blocker); seen[expiringEvent] || seen[keptEvent] {
		t.Fatalf("blocker sees the blocked sender's events before pruning: %v", seen)
	}

	f.expire(t, ctx, expiring.ID)
	removed, _, err := f.store.PruneExpiredContent(ctx, time.Now().UTC())
	if err != nil || removed != 1 {
		t.Fatalf("prune removed %d, err = %v, want 1", removed, err)
	}
	if testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM message_envelopes WHERE id = ?`, expiring.ID) != 0 {
		t.Fatal("the envelope row survived pruning")
	}
	if seen := f.eventIDs(t, ctx, f.blocker); seen[expiringEvent] || seen[keptEvent] {
		t.Fatalf("blocker sees the blocked sender's events after the envelope was pruned: %v", seen)
	}
	if seen := f.eventIDs(t, ctx, f.bystander); !seen[keptEvent] {
		t.Fatalf("bystander lost an unrelated event: %v", seen)
	}
	_, oldest, latest, err := f.store.SyncBounds(ctx, f.blocker.Account.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, hidden := range []int64{expiringEvent, keptEvent} {
		if oldest == hidden || latest == hidden {
			t.Fatalf("sync bounds (%d, %d) are set by the hidden event %d", oldest, latest, hidden)
		}
	}
}

func TestSyncBlockFilterHoldsAfterIdempotencyCleanupDeletesTheEnvelope(t *testing.T) {
	ctx := context.Background()
	f := newSyncVisibilityFixture(t, ctx)
	soon := time.Now().UTC().Add(time.Hour)
	first, firstEvent := f.send(t, ctx, "retry-key", &soon)
	f.expire(t, ctx, first.ID)
	// Sending again with the same device and key replaces the expired row.
	second, secondEvent := f.send(t, ctx, "retry-key", nil)
	if second.ID == first.ID {
		t.Fatal("the retry reused the expired envelope")
	}
	if testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM message_envelopes WHERE id = ?`, first.ID) != 0 {
		t.Fatal("the expired envelope survived the idempotent retry")
	}
	if seen := f.eventIDs(t, ctx, f.blocker); seen[firstEvent] || seen[secondEvent] {
		t.Fatalf("blocker sees the blocked sender's events: %v", seen)
	}
	if seen := f.eventIDs(t, ctx, f.bystander); !seen[secondEvent] {
		t.Fatalf("bystander lost the retried message's event: %v", seen)
	}
}
