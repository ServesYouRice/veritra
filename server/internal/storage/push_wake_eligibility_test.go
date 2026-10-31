package storage

import (
	"context"
	"testing"
	"time"

	"private-messenger/server/internal/domain"
)

type wakeFixture struct {
	store        *Store
	owner        AccountDevice
	conversation domain.Conversation
}

func newWakeFixture(t *testing.T, ctx context.Context, names ...string) (*wakeFixture, map[string]AccountDevice) {
	t.Helper()
	store, _ := newTestStore(t, ctx)
	t.Cleanup(func() { store.Close() })
	owner := createTestOwner(t, ctx, store)
	invite, err := store.CreateInvite(ctx, owner.Account.ID, len(names), nil)
	if err != nil {
		t.Fatal(err)
	}
	members := map[string]AccountDevice{}
	for _, name := range names {
		member := registerTestMember(t, ctx, store, invite.Code, name)
		members[name] = member
		if _, err := store.CreatePushSubscription(ctx, member.Account.ID, member.Device.ID, "fcm", "https://push.example.test/"+name, "", ""); err != nil {
			t.Fatal(err)
		}
	}
	return &wakeFixture{store: store, owner: owner}, members
}

func (f *wakeFixture) group(t *testing.T, ctx context.Context, members ...AccountDevice) {
	t.Helper()
	ids := make([]string, 0, len(members))
	for _, member := range members {
		ids = append(ids, member.Account.ID)
	}
	conversation, err := f.store.CreateConversation(ctx, CreateConversationInput{Kind: "group", CreatedBy: f.owner.Account.ID, MemberAccountIDs: ids})
	if err != nil {
		t.Fatal(err)
	}
	f.conversation = conversation
}

func (f *wakeFixture) send(t *testing.T, ctx context.Context, key string) int64 {
	t.Helper()
	_, _, eventID, err := f.store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{
		ConversationID: f.conversation.ID, SenderAccountID: f.owner.Account.ID, SenderDeviceID: f.owner.Device.ID,
		IdempotencyKey: key, Ciphertext: []byte("ciphertext"), CryptoProtocol: "mls-openmls-todo",
	})
	if err != nil || eventID == 0 {
		t.Fatalf("send: event %d, err = %v", eventID, err)
	}
	return eventID
}

func backlogRows(t *testing.T, ctx context.Context, store *Store) int64 {
	t.Helper()
	backlog, err := store.PushWakeBacklog(ctx, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	var rows int64
	for _, item := range backlog {
		rows += item.Rows
	}
	return rows
}

// VAL-271: a job whose recipient muted the conversation after it was queued
// is dropped, not kept for a later unmute to fire.
func TestWakeJobOfARecipientWhoMutedIsDroppedNotKept(t *testing.T) {
	ctx := context.Background()
	f, members := newWakeFixture(t, ctx, "bea")
	bea := members["bea"]
	f.group(t, ctx, bea)
	f.send(t, ctx, "wake-1")
	if got := backlogRows(t, ctx, f.store); got != 1 {
		t.Fatalf("setup: backlog = %d, want 1", got)
	}
	if err := f.store.SetConversationNotificationMute(ctx, f.conversation.ID, bea.Account.ID, true, nil); err != nil {
		t.Fatal(err)
	}
	if got := backlogRows(t, ctx, f.store); got != 0 {
		t.Fatalf("backlog after the recipient muted = %d, want 0", got)
	}
	jobs, abandoned, err := f.store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now().UTC(), time.Minute)
	if err != nil || len(jobs) != 0 || abandoned != 0 {
		t.Fatalf("claim for a muted recipient: %d jobs, abandoned %d, err = %v, want none", len(jobs), abandoned, err)
	}
	if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM push_wake_jobs`); n != 0 {
		t.Fatalf("%d wake jobs left for a muted recipient", n)
	}
	if err := f.store.SetConversationNotificationMute(ctx, f.conversation.ID, bea.Account.ID, false, nil); err != nil {
		t.Fatal(err)
	}
	jobs, _, err = f.store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now().UTC(), time.Minute)
	if err != nil || len(jobs) != 0 {
		t.Fatalf("claim after the unmute: %d jobs, err = %v, want the stale wake gone", len(jobs), err)
	}
}

// VAL-309: ineligible jobs are removed in bounded steps and never counted as
// abandoned, whatever their number; only expired jobs that were still
// eligible are.
func TestExpiredIneligibleWakeJobsAreNeverCountedAsAbandoned(t *testing.T) {
	for _, withIneligible := range []bool{true, false} {
		name := "mixed"
		if !withIneligible {
			name = "only eligible"
		}
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f, members := newWakeFixture(t, ctx, "outsider", "revoked", "blocker", "muted", "eligible")
			f.group(t, ctx, members["revoked"], members["blocker"], members["muted"], members["eligible"])
			// "outsider" has a subscription but is not a member.
			if _, err := f.store.db.ExecContext(ctx, `UPDATE devices SET revoked_at = ? WHERE id = ?`, nowString(), members["revoked"].Device.ID); err != nil {
				t.Fatal(err)
			}
			if _, err := f.store.BlockAccount(ctx, members["blocker"].Account.ID, f.owner.Account.ID); err != nil {
				t.Fatal(err)
			}
			if err := f.store.SetConversationNotificationMute(ctx, f.conversation.ID, members["muted"].Account.ID, true, nil); err != nil {
				t.Fatal(err)
			}
			subscriptionOf := func(name string) string {
				var id string
				if err := f.store.db.QueryRowContext(ctx, `SELECT id FROM push_subscriptions WHERE account_id = ?`, members[name].Account.ID).Scan(&id); err != nil {
					t.Fatal(err)
				}
				return id
			}
			expired := formatTime(time.Now().UTC().Add(-time.Hour))
			seed := func(recipient string, count int) {
				for i := 0; i < count; i++ {
					result, err := f.store.db.ExecContext(ctx, `INSERT INTO sync_events(event_type, account_id, conversation_id, payload_json, created_at) VALUES('message.envelope.created', NULL, ?, '{}', ?)`, f.conversation.ID, expired)
					if err != nil {
						t.Fatal(err)
					}
					eventID, _ := result.LastInsertId()
					if _, err := f.store.db.ExecContext(ctx, `INSERT INTO push_wake_jobs(sync_event_id, conversation_id, sender_account_id, recipient_account_id, subscription_id, created_at, next_attempt_at, expires_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
						eventID, f.conversation.ID, f.owner.Account.ID, members[recipient].Account.ID, subscriptionOf(recipient), expired, expired, expired); err != nil {
						t.Fatal(err)
					}
				}
			}
			const eligibleExpired = 3
			seed("eligible", eligibleExpired)
			if withIneligible {
				perCause := (2*pushWakeBatchLimit + 3 + 3) / 4
				for _, recipient := range []string{"outsider", "revoked", "blocker", "muted"} {
					seed(recipient, perCause)
				}
			}
			var abandonedTotal int64
			for call := 0; call < 20; call++ {
				before := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM push_wake_jobs`)
				jobs, abandoned, err := f.store.ClaimPushWakeJobs(ctx, "fcm", 10, time.Now().UTC(), time.Minute)
				if err != nil {
					t.Fatal(err)
				}
				if len(jobs) != 0 {
					t.Fatalf("claim returned %d jobs, every seeded job is expired or ineligible", len(jobs))
				}
				abandonedTotal += abandoned
				removed := before - testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM push_wake_jobs`)
				// An expiry delete and an ineligible delete, each bounded.
				if removed > 2*pushWakeBatchLimit {
					t.Fatalf("one claim removed %d jobs, over two statements of %d", removed, pushWakeBatchLimit)
				}
				if removed == 0 {
					break
				}
			}
			if abandonedTotal != eligibleExpired {
				t.Fatalf("abandoned in total = %d, want only the %d expired jobs that were still eligible", abandonedTotal, eligibleExpired)
			}
			if n := testRowCount(t, ctx, f.store, `SELECT COUNT(*) FROM push_wake_jobs`); n != 0 {
				t.Fatalf("%d wake jobs remain", n)
			}
			if got := backlogRows(t, ctx, f.store); got != 0 {
				t.Fatalf("backlog = %d, want 0", got)
			}
		})
	}
}

func TestWakeBacklogExcludesIneligibleJobs(t *testing.T) {
	ctx := context.Background()
	f, members := newWakeFixture(t, ctx, "blocker", "other")
	f.group(t, ctx, members["blocker"], members["other"])
	f.send(t, ctx, "backlog-1")
	if got := backlogRows(t, ctx, f.store); got != 2 {
		t.Fatalf("backlog = %d, want one job per recipient", got)
	}
	if _, err := f.store.BlockAccount(ctx, members["blocker"].Account.ID, f.owner.Account.ID); err != nil {
		t.Fatal(err)
	}
	if got := backlogRows(t, ctx, f.store); got != 1 {
		t.Fatalf("backlog after a block = %d, want only the recipient who can still be woken", got)
	}
}
