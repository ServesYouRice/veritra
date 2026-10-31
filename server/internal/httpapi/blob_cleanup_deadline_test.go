package httpapi

import (
	"context"
	"errors"
	"io"
	"path/filepath"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
	"private-messenger/server/migrations"
)

// stallingBlobStore's Delete uses up its whole deadline and then fails, as
// a hung filesystem or object store would.
type stallingBlobStore struct{}

func (stallingBlobStore) Check(context.Context) error { return nil }
func (stallingBlobStore) PutEncryptedBlob(context.Context, io.Reader) (uploads.BlobRef, error) {
	return uploads.BlobRef{}, errors.New("not implemented")
}
func (stallingBlobStore) Open(context.Context, uploads.BlobRef) (uploads.Blob, error) {
	return nil, errors.New("not implemented")
}
func (stallingBlobStore) Delete(ctx context.Context, _ string) error {
	<-ctx.Done()
	return ctx.Err()
}

// C-8eb6c45ffd50: when the delete of an uncommitted blob times out, the
// durable fallback (the deletion queue) gets its own deadline instead of the
// exhausted one, so the blob is not forgotten.
func TestUncommittedBlobCleanupQueuesAfterADeleteTimeout(t *testing.T) {
	previous := blobCleanupTimeout
	blobCleanupTimeout = 50 * time.Millisecond
	defer func() { blobCleanupTimeout = previous }()

	dir := t.TempDir()
	store, err := storage.Open(context.Background(), config.Config{
		DataDir: dir, DatabasePath: filepath.Join(dir, "db.sqlite"), StoragePath: filepath.Join(dir, "blobs"),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Migrate(context.Background(), migrations.FS); err != nil {
		t.Fatal(err)
	}
	api := &API{Store: store, Blobs: stallingBlobStore{}}
	api.cleanupUncommittedBlob(context.Background(), "blob_uncommitted_stalled")

	pending, err := store.PendingBlobDeletions(context.Background(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 || pending[0] != "blob_uncommitted_stalled" {
		t.Fatalf("queued deletions = %v, want the stalled blob", pending)
	}
}
