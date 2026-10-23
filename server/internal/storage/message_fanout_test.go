package storage

import (
	"context"
	"testing"

	"private-messenger/server/internal/domain"
)

// Card I36: a failure while the commit records its fanout (the recipient
// snapshot and the durable wake jobs) must roll the whole message back. A
// committed message whose wake work was lost is the failure this prevents.
func TestFanoutFailureRollsBackTheCommittedMessage(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t, ctx)
	defer store.Close()
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, 1, nil)
	if err != nil {
		t.Fatalf("create invite: %v", err)
	}
	member := registerTestMember(t, ctx, store, invite.Code, "fanoutmember")
	conversation, err := store.CreateConversation(ctx, CreateConversationInput{
		Kind:             "group",
		CreatedBy:        owner.Account.ID,
		MemberAccountIDs: []string{member.Account.ID},
	})
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, `INSERT INTO push_subscriptions(id, account_id, provider, endpoint, created_at) VALUES ('psub_fanout', ?, 'fcm', 'https://push.invalid/fanout', ?)`, member.Account.ID, nowString()); err != nil {
		t.Fatalf("add member push subscription: %v", err)
	}
	counts := func() (messages, events, jobs int) {
		t.Helper()
		for query, target := range map[string]*int{
			`SELECT COUNT(*) FROM message_envelopes`: &messages,
			`SELECT COUNT(*) FROM sync_events`:       &events,
			`SELECT COUNT(*) FROM push_wake_jobs`:    &jobs,
		} {
			if err := store.db.QueryRowContext(ctx, query).Scan(target); err != nil {
				t.Fatalf("%s: %v", query, err)
			}
		}
		return messages, events, jobs
	}
	beforeMessages, beforeEvents, beforeJobs := counts()
	envelope := domain.MessageEnvelope{
		ConversationID:  conversation.ID,
		SenderAccountID: owner.Account.ID,
		SenderDeviceID:  owner.Device.ID,
		IdempotencyKey:  "fanout-failure",
		Ciphertext:      []byte("fanout ciphertext"),
		CryptoProtocol:  "mls10-openmls-v1",
	}

	if _, err := store.db.ExecContext(ctx, `CREATE TRIGGER inject_fanout_failure BEFORE INSERT ON push_wake_jobs BEGIN SELECT RAISE(ABORT, 'injected fanout failure'); END`); err != nil {
		t.Fatalf("install failure trigger: %v", err)
	}
	if _, _, _, _, err := store.SaveMessageEnvelopeWithSyncEventAndRecipients(ctx, envelope); err == nil {
		t.Fatal("commit succeeded although its fanout could not be recorded")
	}
	if messages, events, jobs := counts(); messages != beforeMessages || events != beforeEvents || jobs != beforeJobs {
		t.Fatalf("failed fanout left durable rows: messages %d->%d events %d->%d jobs %d->%d",
			beforeMessages, messages, beforeEvents, events, beforeJobs, jobs)
	}

	// The client retries with the same idempotency key once the fault clears:
	// it is a fresh commit, not a duplicate that would skip fanout.
	if _, err := store.db.ExecContext(ctx, `DROP TRIGGER inject_fanout_failure`); err != nil {
		t.Fatalf("drop failure trigger: %v", err)
	}
	saved, duplicate, eventID, recipients, err := store.SaveMessageEnvelopeWithSyncEventAndRecipients(ctx, envelope)
	if err != nil {
		t.Fatalf("retry after fault: %v", err)
	}
	if duplicate || eventID == 0 || saved.ID == "" {
		t.Fatalf("retry was not a fresh commit: duplicate=%v event=%d id=%q", duplicate, eventID, saved.ID)
	}
	want := map[string]bool{owner.Account.ID: true, member.Account.ID: true}
	if len(recipients) != len(want) {
		t.Fatalf("recipients = %v, want the conversation members", recipients)
	}
	for _, recipient := range recipients {
		if !want[recipient] {
			t.Fatalf("unexpected recipient %q in %v", recipient, recipients)
		}
	}
	if messages, events, jobs := counts(); messages != beforeMessages+1 || events != beforeEvents+1 || jobs != beforeJobs+1 {
		t.Fatalf("retry rows: messages %d->%d events %d->%d jobs %d->%d, want +1 each",
			beforeMessages, messages, beforeEvents, events, beforeJobs, jobs)
	}
}
