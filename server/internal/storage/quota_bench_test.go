package storage

import (
	"bytes"
	"context"
	"fmt"
	"path/filepath"
	"sync/atomic"
	"testing"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/uploads"
)

// T49B: quota SQL, upload admission metadata and blob-directory reconciliation.

var quotaProfiles = []benchProfile{
	{Name: "attach1k", Accounts: 50, AttachmentRows: 1_000, AttachmentBytes: 64 << 10, BackupRows: 50},
	{Name: "attach10k", Accounts: 500, AttachmentRows: 10_000, AttachmentBytes: 64 << 10, BackupRows: 500},
	{Name: "attach100k", Accounts: 500, AttachmentRows: 100_000, AttachmentBytes: 64 << 10, BackupRows: 500},
}

func BenchmarkQuotaSQL(b *testing.B) {
	ctx := context.Background()
	for _, p := range quotaProfiles {
		store := newBenchStore(b, ctx)
		ds := seedBenchDataset(b, ctx, store, p)
		b.Logf("dataset %+v", p)
		b.Run(p.Name+"/EnforceBlobQuota", func(b *testing.B) {
			for b.Loop() {
				tx, err := store.db.BeginTx(ctx, nil)
				if err != nil {
					b.Fatal(err)
				}
				err = store.enforceBlobQuota(ctx, tx, ds.HotAccount, 1<<20)
				_ = tx.Rollback()
				if err != nil {
					b.Fatal(err)
				}
			}
		})
		// Full metadata admission: membership-free attachment row insert
		// under the quota transaction. Each iteration adds one row.
		b.Run(p.Name+"/CreateAttachmentEnvelope", func(b *testing.B) {
			i := 0
			for b.Loop() {
				i++
				if _, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
					OwnerAccountID: ds.Accounts[i%len(ds.Accounts)], StorageKey: benchID("blob", 5_000_000+i),
					CiphertextSHA256: fmt.Sprintf("%064x", i), SizeBytes: 1024,
				}); err != nil {
					b.Fatal(err)
				}
			}
			if _, err := store.db.ExecContext(ctx, `DELETE FROM attachment_envelopes WHERE storage_key >= ?`, benchID("blob", 5_000_000)); err != nil {
				b.Fatal(err)
			}
		})
		// Concurrent admissions serialize on the single writer connection;
		// this is the race-safe path the quota relies on.
		b.Run(p.Name+"/CreateAttachmentEnvelopeParallel", func(b *testing.B) {
			var seq atomic.Int64
			b.RunParallel(func(pb *testing.PB) {
				for pb.Next() {
					i := seq.Add(1)
					if _, err := store.CreateAttachmentEnvelope(ctx, domain.AttachmentEnvelope{
						OwnerAccountID: ds.Accounts[int(i)%len(ds.Accounts)], StorageKey: benchID("blob", 6_000_000+int(i)),
						CiphertextSHA256: fmt.Sprintf("%064x", i), SizeBytes: 1024,
					}); err != nil {
						b.Error(err)
						return
					}
				}
			})
			if _, err := store.db.ExecContext(ctx, `DELETE FROM attachment_envelopes WHERE storage_key >= ?`, benchID("blob", 6_000_000)); err != nil {
				b.Fatal(err)
			}
		})
	}
}

// BenchmarkBlobDeletionReconcile mirrors App.reconcileBlobDeletions for one
// 500-key batch: read the queue, delete each local blob, complete its row.
func BenchmarkBlobDeletionReconcile(b *testing.B) {
	ctx := context.Background()
	store := newBenchStore(b, ctx)
	blobs, err := uploads.NewLocalStore(filepath.Join(b.TempDir(), "blobs"))
	if err != nil {
		b.Fatal(err)
	}
	const batch = 500
	payload := bytes.Repeat([]byte{0xA5}, 4<<10)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		for j := 0; j < batch; j++ {
			key, _, _, err := blobs.PutEncryptedBlob(ctx, bytes.NewReader(payload))
			if err != nil {
				b.Fatal(err)
			}
			if err := store.QueueBlobDeletion(ctx, key); err != nil {
				b.Fatal(err)
			}
		}
		b.StartTimer()
		keys, err := store.PendingBlobDeletions(ctx, batch)
		if err != nil || len(keys) != batch {
			b.Fatalf("pending: %d %v", len(keys), err)
		}
		for _, key := range keys {
			if err := blobs.Delete(ctx, key); err != nil {
				b.Fatal(err)
			}
			if err := store.CompleteBlobDeletion(ctx, key); err != nil {
				b.Fatal(err)
			}
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*batch), "ns/blob")
}

// BenchmarkListDatabaseBlobReferences measures the backup/restore
// reconciliation read that enumerates every referenced blob.
func BenchmarkListDatabaseBlobReferences(b *testing.B) {
	ctx := context.Background()
	for _, p := range quotaProfiles {
		store := newBenchStore(b, ctx)
		seedBenchDataset(b, ctx, store, p)
		path := ""
		if err := store.db.reader.QueryRowContext(ctx, `SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&path); err != nil {
			b.Fatal(err)
		}
		if _, err := store.db.writer.ExecContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
			b.Fatal(err)
		}
		b.Run(p.Name, func(b *testing.B) {
			for b.Loop() {
				refs, _, err := ListDatabaseBlobReferences(ctx, path)
				if err != nil || len(refs) < p.AttachmentRows {
					b.Fatalf("refs: %d %v", len(refs), err)
				}
			}
		})
	}
}
