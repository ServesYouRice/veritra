package storage

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"

	"private-messenger/server/internal/domain"
)

// T49A: conversation reads, sync bounds and device-seen writes.

func benchProfiles() []benchProfile { return []benchProfile{benchSmall, benchLarge} }

func BenchmarkConversationReads(b *testing.B) {
	ctx := context.Background()
	for _, p := range benchProfiles() {
		store := newBenchStore(b, ctx)
		ds := seedBenchDataset(b, ctx, store, p)
		b.Logf("dataset %s", p)
		b.Run(p.Name+"/ListConversationsPage100", func(b *testing.B) {
			for b.Loop() {
				got, err := store.ListConversationsPage(ctx, ds.HotAccount, 100, "")
				if err != nil || len(got) == 0 {
					b.Fatalf("list conversations: %d %v", len(got), err)
				}
			}
		})
		b.Run(p.Name+"/ListMessagesLatest100", func(b *testing.B) {
			for b.Loop() {
				got, err := store.ListMessages(ctx, ds.HotConv, ds.HotAccount, ListMessagesOptions{Limit: 100})
				if err != nil || len(got) == 0 {
					b.Fatalf("list messages: %d %v", len(got), err)
				}
			}
		})
		b.Run(p.Name+"/ListMessagesBeforeMid100", func(b *testing.B) {
			for b.Loop() {
				got, err := store.ListMessages(ctx, ds.HotConv, ds.HotAccount, ListMessagesOptions{Limit: 100, BeforeID: ds.DeepMsgID})
				if err != nil || len(got) == 0 {
					b.Fatalf("list messages before: %d %v", len(got), err)
				}
			}
		})
	}
}

func BenchmarkSyncBounds(b *testing.B) {
	ctx := context.Background()
	for _, p := range benchProfiles() {
		store := newBenchStore(b, ctx)
		ds := seedBenchDataset(b, ctx, store, p)
		b.Logf("dataset %s", p)
		b.Run(p.Name+"/SyncBounds", func(b *testing.B) {
			for b.Loop() {
				if _, _, latest, err := store.SyncBounds(ctx, ds.HotAccount); err != nil || latest == 0 {
					b.Fatalf("sync bounds: %d %v", latest, err)
				}
			}
		})
		b.Run(p.Name+"/ListSyncEventsFromStart100", func(b *testing.B) {
			for b.Loop() {
				if got, err := store.ListSyncEvents(ctx, ds.HotAccount, ds.HotDevice, 0, 100); err != nil || len(got) == 0 {
					b.Fatalf("list sync events: %d %v", len(got), err)
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

func BenchmarkDeviceSeen(b *testing.B) {
	ctx := context.Background()
	store := newBenchStore(b, ctx)
	ds := seedBenchDataset(b, ctx, store, benchSmall)
	b.Logf("dataset %s", benchSmall)
	for _, device := range ds.Devices {
		if err := store.MarkDeviceSeen(ctx, device); err != nil {
			b.Fatal(err)
		}
	}
	b.Run("Throttled", func(b *testing.B) {
		for b.Loop() {
			if err := store.MarkDeviceSeen(ctx, ds.HotDevice); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("ThrottledParallel", func(b *testing.B) {
		var n atomic.Int64
		b.RunParallel(func(pb *testing.PB) {
			for pb.Next() {
				device := ds.Devices[int(n.Add(1))%len(ds.Devices)]
				if err := store.MarkDeviceSeen(ctx, device); err != nil {
					b.Error(err)
					return
				}
			}
		})
	})
	b.Run("Write", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			b.StopTimer()
			if _, err := store.db.ExecContext(ctx, `UPDATE devices SET last_seen_at = NULL WHERE id = ?`, ds.HotDevice); err != nil {
				b.Fatal(err)
			}
			b.StartTimer()
			if err := store.MarkDeviceSeen(ctx, ds.HotDevice); err != nil {
				b.Fatal(err)
			}
		}
	})
	// Device-seen updates share the single writer connection with message
	// writes; this measures a durable send while seen writes run alongside.
	b.Run("SendWithParallelSeen", func(b *testing.B) {
		stop := make(chan struct{})
		done := make(chan struct{})
		go func() {
			defer close(done)
			for i := 0; ; i++ {
				select {
				case <-stop:
					return
				default:
				}
				_ = store.MarkDeviceSeen(ctx, ds.Devices[i%len(ds.Devices)])
			}
		}()
		ciphertext := make([]byte, benchSmall.CiphertextBytes)
		i := 0
		for b.Loop() {
			i++
			if _, _, _, err := store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{
				ConversationID: ds.HotConv, SenderAccountID: ds.HotAccount, SenderDeviceID: ds.HotDevice,
				IdempotencyKey: fmt.Sprintf("bench-seen-%d", i), Ciphertext: ciphertext, CryptoProtocol: "mls",
			}); err != nil {
				b.Fatal(err)
			}
		}
		close(stop)
		<-done
	})
}

func BenchmarkSendMessage(b *testing.B) {
	ctx := context.Background()
	for _, p := range benchProfiles() {
		store := newBenchStore(b, ctx)
		ds := seedBenchDataset(b, ctx, store, p)
		b.Logf("dataset %s", p)
		ciphertext := make([]byte, p.CiphertextBytes)
		b.Run(p.Name+"/SaveMessageEnvelopeWithSyncEvent", func(b *testing.B) {
			i := 0
			for b.Loop() {
				i++
				if _, _, _, err := store.SaveMessageEnvelopeWithSyncEvent(ctx, domain.MessageEnvelope{
					ConversationID: ds.HotConv, SenderAccountID: ds.HotAccount, SenderDeviceID: ds.HotDevice,
					IdempotencyKey: fmt.Sprintf("bench-send-%s-%d", b.Name(), i), Ciphertext: ciphertext, CryptoProtocol: "mls",
				}); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
