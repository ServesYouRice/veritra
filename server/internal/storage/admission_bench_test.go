package storage

import (
	"context"
	"fmt"
	"testing"
)

// T49D evidence: how the per-account read paths scale with the number of
// conversations an account belongs to, which a membership limit bounds.
// Run: go test -run '^$' -bench Memberships -benchtime 20x ./internal/storage
func BenchmarkMembershipsPerAccount(b *testing.B) {
	ctx := context.Background()
	for _, memberships := range []int{200, 1000, 2000} {
		p := benchProfile{Name: fmt.Sprintf("m%d", memberships), Accounts: 200, Conversations: memberships,
			HotMemberships: memberships, MembersPerConv: 4, MessagesPerConv: 10, AccountEvents: 100,
			CiphertextBytes: 256, ReadReceiptRatio: 2}
		store := newBenchStore(b, ctx)
		ds := seedBenchDataset(b, ctx, store, p)
		b.Run(p.Name+"/ListConversationsPage100", func(b *testing.B) {
			for b.Loop() {
				if got, err := store.ListConversationsPage(ctx, ds.HotAccount, 100, ""); err != nil || len(got) == 0 {
					b.Fatalf("list conversations: %d %v", len(got), err)
				}
			}
		})
		b.Run(p.Name+"/SyncBounds", func(b *testing.B) {
			for b.Loop() {
				if _, _, latest, err := store.SyncBounds(ctx, ds.HotAccount); err != nil || latest == 0 {
					b.Fatalf("sync bounds: %d %v", latest, err)
				}
			}
		})
		b.Run(p.Name+"/ListSyncEventsFromMid100", func(b *testing.B) {
			for b.Loop() {
				if _, err := store.ListSyncEvents(ctx, ds.HotAccount, ds.HotDevice, ds.MidEventID, 100); err != nil {
					b.Fatalf("list sync events: %v", err)
				}
			}
		})
	}
}
