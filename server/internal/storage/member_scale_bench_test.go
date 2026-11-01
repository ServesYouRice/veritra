package storage

import (
	"context"
	"fmt"
	"testing"

	"private-messenger/server/internal/domain"
)

// C8 evidence: how the per-conversation write and read paths scale with the
// number of members, the quantity the member limit bounds.
// Run: go test -run '^$' -bench ConversationMembersScale -benchtime 30x ./internal/storage
func BenchmarkConversationMembersScale(b *testing.B) {
	ctx := context.Background()
	for _, members := range []int{100, 250, 500, 1000} {
		p := benchProfile{Name: fmt.Sprintf("n%d", members), Accounts: members, Conversations: 1, HotMemberships: 1,
			MembersPerConv: 1, MessagesPerConv: 50, CiphertextBytes: 256}
		store := newBenchStore(b, ctx)
		ds := seedBenchDataset(b, ctx, store, p)
		// The seeded conversation is a two-person DM; make it a group of every account.
		if _, err := store.db.ExecContext(ctx, `UPDATE conversations SET kind = 'group' WHERE id = ?`, ds.HotConv); err != nil {
			b.Fatal(err)
		}
		for i, account := range ds.Accounts {
			if _, err := store.db.ExecContext(ctx, `INSERT OR IGNORE INTO memberships(id, account_id, conversation_id, role, created_at) VALUES(?, ?, ?, 'member', ?)`,
				benchID("memc8", i), account, ds.HotConv, nowString()); err != nil {
				b.Fatal(err)
			}
		}
		ciphertext := make([]byte, p.CiphertextBytes)
		b.Run(p.Name+"/SendFanout", func(b *testing.B) {
			i := 0
			for b.Loop() {
				i++
				_, _, _, recipients, err := store.SaveMessageEnvelopeWithSyncEventAndRecipients(ctx, domain.MessageEnvelope{
					ConversationID: ds.HotConv, SenderAccountID: ds.HotAccount, SenderDeviceID: ds.HotDevice,
					IdempotencyKey: fmt.Sprintf("c8-send-%d", i), Ciphertext: ciphertext, CryptoProtocol: "mls",
				})
				if err != nil {
					b.Fatal(err)
				}
				if len(recipients) < members-1 {
					b.Fatalf("recipients = %d, want at least %d", len(recipients), members-1)
				}
			}
		})
		b.Run(p.Name+"/ListMembers", func(b *testing.B) {
			for b.Loop() {
				got, err := store.ListConversationMembers(ctx, ds.HotConv, ds.HotAccount)
				if err != nil || len(got) != members {
					b.Fatalf("members = %d, %v", len(got), err)
				}
			}
		})
		b.Run(p.Name+"/ListMessagesPage50", func(b *testing.B) {
			for b.Loop() {
				if got, err := store.ListMessages(ctx, ds.HotConv, ds.Accounts[members-1], ListMessagesOptions{Limit: 50}); err != nil || len(got) == 0 {
					b.Fatalf("messages = %d, %v", len(got), err)
				}
			}
		})
	}
}
