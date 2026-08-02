package uploads

import (
	"context"
	"io"
	"time"
)

type Store interface {
	Check(ctx context.Context) error
	PutEncryptedBlob(ctx context.Context, r io.Reader) (storageKey string, sha256Hex string, size int64, err error)
	Open(ctx context.Context, storageKey, expectedSHA256 string, expectedSize int64) (ReadSeekCloser, error)
	Delete(ctx context.Context, storageKey string) error
}

type ReadSeekCloser interface {
	io.Reader
	io.Seeker
	io.Closer
}

// TemporaryFileCleaner is an optional capability of stores that stage writes
// locally. Remote object stores do not need to implement it.
type TemporaryFileCleaner interface {
	CleanupTemporaryFiles(ctx context.Context, olderThan time.Time) (int, error)
}
