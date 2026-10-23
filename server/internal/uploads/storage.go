package uploads

import (
	"context"
	"io"
	"time"
)

// ChunkSize is the span covered by one digest in a chunk-digest record.
const ChunkSize = 64 << 10

// BlobRef names a stored blob and the integrity data recorded when it was
// written. The database row that holds it is the trust anchor.
//
// ChunkDigests is an opaque record produced by PutEncryptedBlob: version
// byte 0x01, the SHA-256 of the whole blob, then the SHA-256 of each
// ChunkSize piece in order (the last may be shorter). It lets Open verify
// only the chunks a reader touches. It is nil for blobs stored before
// records existed (migration 0034); Open then verifies the whole blob first,
// as before.
type BlobRef struct {
	StorageKey   string
	SHA256       string
	Size         int64
	ChunkDigests []byte
}

type Store interface {
	Check(ctx context.Context) error
	PutEncryptedBlob(ctx context.Context, r io.Reader) (BlobRef, error)
	// Open returns a reader that only ever returns bytes verified against
	// ref. A failed check returns ErrBlobIntegrity, from Open or from a
	// later read.
	Open(ctx context.Context, ref BlobRef) (Blob, error)
	Delete(ctx context.Context, storageKey string) error
}

type ReadSeekCloser interface {
	io.Reader
	io.Seeker
	io.Closer
}

// Blob is an opened blob. Its methods are safe for concurrent use.
type Blob interface {
	ReadSeekCloser
	// VerifyCurrent verifies the data at the current offset without
	// consuming it, so a caller can report ErrBlobIntegrity before it
	// starts a response.
	VerifyCurrent() error
	// Err returns the error that stopped reads, if any. A failed read keeps
	// failing.
	Err() error
	// RecomputedChunkDigests returns the record that Open built while it
	// verified the whole blob because ref had no usable record, or nil. The
	// caller may store it for ref.
	RecomputedChunkDigests() []byte
}

// TemporaryFileCleaner is an optional capability of stores that stage writes
// locally. Remote object stores do not need to implement it.
type TemporaryFileCleaner interface {
	CleanupTemporaryFiles(ctx context.Context, olderThan time.Time) (int, error)
}
