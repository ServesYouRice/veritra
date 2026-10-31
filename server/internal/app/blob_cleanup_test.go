package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/uploads"
)

func TestBlobDeletionReconciliationRetriesFailure(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	application, err := New(ctx, config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "test.db"),
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "test", SetupToken: "test-token",
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()
	key := "blob_00000000000000000000000000000003"
	if err := application.Store.QueueBlobDeletion(ctx, key); err != nil {
		t.Fatal(err)
	}
	failing := &toggleDeleteStore{Store: application.Blobs, fail: true}
	application.Blobs = failing
	application.reconcileBlobDeletions(ctx)
	keys, err := application.Store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 1 {
		t.Fatalf("pending after failure = %#v, err = %v", keys, err)
	}
	failing.fail = false
	application.reconcileBlobDeletions(ctx)
	keys, err = application.Store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 0 {
		t.Fatalf("pending after retry = %#v, err = %v", keys, err)
	}
}

func TestBlobDeletionSweepWithAlwaysFailingDeletesTerminatesAndReachesEveryKey(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	application, err := New(ctx, config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "test.db"),
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "test", SetupToken: "test-token",
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer application.Close()
	const queued = 520
	for i := 0; i < queued; i++ {
		if err := application.Store.QueueBlobDeletion(ctx, fmt.Sprintf("blob_%032d", i)); err != nil {
			t.Fatal(err)
		}
	}
	counting := &countingFailingDeleteStore{Store: application.Blobs, attempted: map[string]int{}}
	application.Blobs = counting
	// The sweep ends at its time budget or batch ceiling when every delete
	// fails; a short budget keeps the test quick without changing that rule.
	application.retentionBudget = 4 * time.Second
	done := make(chan struct{})
	go func() {
		defer close(done)
		application.reconcileBlobDeletions(ctx)
	}()
	select {
	case <-done:
	case <-time.After(time.Minute):
		t.Fatal("sweep with always-failing deletes did not terminate")
	}
	if len(counting.attempted) != queued {
		t.Fatalf("sweep attempted %d distinct keys, want all %d queued keys", len(counting.attempted), queued)
	}
	keys, err := application.Store.PendingBlobDeletions(ctx, 500)
	if err != nil || len(keys) != 500 {
		t.Fatalf("failing keys must stay queued: pending = %d, err = %v", len(keys), err)
	}
}

type countingFailingDeleteStore struct {
	uploads.Store
	attempted map[string]int
}

func (s *countingFailingDeleteStore) Delete(_ context.Context, key string) error {
	s.attempted[key]++
	return errors.New("injected delete failure")
}

func TestAttachmentDownloadSubrouteGetsExtendedTimeout(t *testing.T) {
	var remaining time.Duration
	handler := routeTimeouts(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		deadline, ok := r.Context().Deadline()
		if !ok {
			t.Fatal("request has no deadline")
		}
		remaining = time.Until(deadline)
	}))
	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/api/v1/attachments/att_example", nil))
	if remaining < 14*time.Minute {
		t.Fatalf("download timeout = %v, want extended timeout", remaining)
	}
}

type toggleDeleteStore struct {
	uploads.Store
	fail bool
}

func (s *toggleDeleteStore) Delete(ctx context.Context, key string) error {
	if s.fail {
		return errors.New("injected delete failure")
	}
	return s.Store.Delete(ctx, key)
}
