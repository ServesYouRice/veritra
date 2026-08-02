package app

import (
	"context"
	"errors"
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
