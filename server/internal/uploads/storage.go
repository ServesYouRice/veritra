package uploads

import (
	"context"
	"io"
	"time"
)

type Store interface {
	Check(ctx context.Context) error
	PutEncryptedBlob(ctx context.Context, r io.Reader) (storageKey string, sha256Hex string, size int64, err error)
	Open(storageKey string) (io.ReadCloser, error)
	Delete(ctx context.Context, storageKey string) error
}

// TemporaryFileCleaner is an optional capability of stores that stage writes
// locally. Remote object stores do not need to implement it.
type TemporaryFileCleaner interface {
	CleanupTemporaryFiles(ctx context.Context, olderThan time.Time) (int, error)
}
