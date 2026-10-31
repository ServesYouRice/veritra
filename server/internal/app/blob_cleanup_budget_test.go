package app

import (
	"context"
	"fmt"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/uploads"
)

// slowDeleteStore makes every blob deletion take a while, as a slow or
// overloaded disk would, and runs onDelete after each one.
type slowDeleteStore struct {
	uploads.Store
	delay    time.Duration
	deletes  atomic.Int32
	onDelete func()
}

func (s *slowDeleteStore) Delete(ctx context.Context, storageKey string) error {
	time.Sleep(s.delay)
	s.deletes.Add(1)
	if s.onDelete != nil {
		s.onDelete()
	}
	return s.Store.Delete(ctx, storageKey)
}

func newBlobCleanupApp(t *testing.T, queued int) *App {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	application, err := New(ctx, config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "test.db"),
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "test", SetupToken: "test-token",
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { application.Close() })
	for i := range queued {
		if err := application.Store.QueueBlobDeletion(ctx, fmt.Sprintf("blob_%032d", i)); err != nil {
			t.Fatal(err)
		}
	}
	return application
}

// One batch holds up to 500 deletions; the sweep's time budget must bound
// them too, not only the gap between batches. What is left stays queued.
func TestBlobDeletionSweepStopsInsideABatchAtItsTimeBudget(t *testing.T) {
	const queued = 100
	application := newBlobCleanupApp(t, queued)
	slow := &slowDeleteStore{Store: application.Blobs, delay: 30 * time.Millisecond}
	application.Blobs = slow
	application.retentionBudget = 100 * time.Millisecond
	started := time.Now()
	application.reconcileBlobDeletions(context.Background())
	if elapsed := time.Since(started); elapsed > 1500*time.Millisecond {
		t.Fatalf("sweep ran %v with a 100ms budget (%d deletions)", elapsed, slow.deletes.Load())
	}
	pending, err := application.Store.PendingBlobDeletions(context.Background(), 500)
	if err != nil {
		t.Fatal(err)
	}
	if done := int(slow.deletes.Load()); done == 0 || done >= queued || len(pending) != queued-done {
		t.Fatalf("deleted %d, pending %d of %d", done, len(pending), queued)
	}
}

// Shutdown cancels the sweep's context; it must stop mid-batch as well.
func TestBlobDeletionSweepStopsInsideABatchWhenCancelled(t *testing.T) {
	const queued = 100
	application := newBlobCleanupApp(t, queued)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	slow := &slowDeleteStore{Store: application.Blobs, delay: time.Millisecond}
	slow.onDelete = func() {
		if slow.deletes.Load() == 3 {
			cancel()
		}
	}
	application.Blobs = slow
	application.reconcileBlobDeletions(ctx)
	if done := slow.deletes.Load(); done != 3 {
		t.Fatalf("sweep made %d deletions after it was cancelled at 3", done)
	}
}
