package uploads

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"private-messenger/server/internal/domain"
)

type LocalStore struct {
	root          string
	syncFile      func(*os.File) error
	rename        func(string, string) error
	remove        func(string) error
	syncDirectory func(string) error
}

var (
	ErrBlobIntegrity     = errors.New("blob integrity check failed")
	ErrInvalidStorageKey = errors.New("invalid blob storage key")
)

func NewLocalStore(root string) (*LocalStore, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	return &LocalStore{
		root:          root,
		syncFile:      (*os.File).Sync,
		rename:        os.Rename,
		remove:        os.Remove,
		syncDirectory: syncDirectory,
	}, nil
}

func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// CleanupTemporaryFiles removes stale partial uploads left by interrupted
// writes while retaining fresh files that may still be in progress.
func (s *LocalStore) CleanupTemporaryFiles(ctx context.Context, olderThan time.Time) (int, error) {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return removed, err
		}
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".tmp") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return removed, err
		}
		if !info.ModTime().Before(olderThan) {
			continue
		}
		if err := os.Remove(filepath.Join(s.root, entry.Name())); err != nil && !os.IsNotExist(err) {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

func (s *LocalStore) Check(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	file, err := os.CreateTemp(s.root, ".readiness-*")
	if err != nil {
		return err
	}
	path := file.Name()
	defer os.Remove(path)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write([]byte{0}); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func (s *LocalStore) PutEncryptedBlob(ctx context.Context, r io.Reader) (BlobRef, error) {
	id, err := domain.NewID("blob")
	if err != nil {
		return BlobRef{}, err
	}
	path := filepath.Join(s.root, id)
	tmp := path + ".tmp"
	file, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return BlobRef{}, err
	}
	closed := false
	defer func() {
		if !closed {
			_ = file.Close()
		}
	}()

	digester := newChunkDigester()
	written, err := io.Copy(file, io.TeeReader(&contextReader{ctx: ctx, reader: r}, digester))
	if err != nil {
		_ = file.Close()
		closed = true
		_ = s.remove(tmp)
		return BlobRef{}, err
	}
	if err := s.syncFile(file); err != nil {
		_ = file.Close()
		closed = true
		_ = s.remove(tmp)
		return BlobRef{}, err
	}
	if err := file.Close(); err != nil {
		closed = true
		_ = s.remove(tmp)
		return BlobRef{}, err
	}
	closed = true
	if err := s.rename(tmp, path); err != nil {
		_ = s.remove(tmp)
		return BlobRef{}, err
	}
	if err := s.syncDirectory(s.root); err != nil {
		_ = s.remove(path)
		_ = s.syncDirectory(s.root)
		return BlobRef{}, err
	}
	full, record := digester.finish()
	return BlobRef{StorageKey: id, SHA256: hex.EncodeToString(full), Size: written, ChunkDigests: record}, nil
}

// Open checks the file's size, then returns a reader that verifies each
// chunk against ref's record before returning any of its bytes. Without a
// usable record it first verifies the whole blob, as before, and builds the
// record in the same pass (Blob.RecomputedChunkDigests).
func (s *LocalStore) Open(ctx context.Context, ref BlobRef) (Blob, error) {
	path, err := s.path(ref.StorageKey)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	fail := func(cause error) (Blob, error) {
		_ = file.Close()
		return nil, cause
	}
	info, err := file.Stat()
	if err != nil {
		return fail(err)
	}
	if !info.Mode().IsRegular() || ref.Size < 0 || info.Size() != ref.Size {
		return fail(ErrBlobIntegrity)
	}
	expected, err := hex.DecodeString(ref.SHA256)
	if err != nil || len(expected) != sha256.Size {
		return fail(ErrBlobIntegrity)
	}
	blob := &verifiedBlob{file: file, size: ref.Size, buffered: -1}
	if digests, ok := parseChunkRecord(ref.ChunkDigests, expected, ref.Size); ok {
		blob.digests = digests
		return blob, nil
	}
	digester := newChunkDigester()
	read, err := io.Copy(digester, &contextReader{ctx: ctx, reader: io.NewSectionReader(file, 0, ref.Size)})
	if err != nil {
		return fail(err)
	}
	full, record := digester.finish()
	if read != ref.Size || subtle.ConstantTimeCompare(full, expected) != 1 {
		return fail(ErrBlobIntegrity)
	}
	blob.digests = record[chunkRecordHeader:]
	blob.recomputed = record
	return blob, nil
}

func (s *LocalStore) Delete(ctx context.Context, storageKey string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path, err := s.path(storageKey)
	if err != nil {
		return err
	}
	err = s.remove(path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (s *LocalStore) path(storageKey string) (string, error) {
	if filepath.Base(storageKey) != storageKey || !domain.ValidID("blob", storageKey) {
		return "", ErrInvalidStorageKey
	}
	return filepath.Join(s.root, storageKey), nil
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	n, err := r.reader.Read(p)
	if err == nil {
		if ctxErr := r.ctx.Err(); ctxErr != nil {
			return n, fmt.Errorf("blob operation interrupted: %w", ctxErr)
		}
	}
	return n, err
}

const (
	chunkRecordVersion = 1
	chunkRecordHeader  = 1 + sha256.Size
)

// parseChunkRecord returns the chunk digests of record when it is a
// well-formed record for a blob of size bytes whose whole digest is full.
func parseChunkRecord(record, full []byte, size int64) ([]byte, bool) {
	if len(record) < chunkRecordHeader || record[0] != chunkRecordVersion ||
		subtle.ConstantTimeCompare(record[1:chunkRecordHeader], full) != 1 {
		return nil, false
	}
	digests := record[chunkRecordHeader:]
	chunks := (size + ChunkSize - 1) / ChunkSize
	if int64(len(digests)) != chunks*sha256.Size {
		return nil, false
	}
	// With at most one chunk the record alone shows whether it matches the
	// whole digest.
	switch chunks {
	case 0:
		empty := sha256.Sum256(nil)
		return digests, subtle.ConstantTimeCompare(full, empty[:]) == 1
	case 1:
		return digests, subtle.ConstantTimeCompare(digests, full) == 1
	}
	return digests, true
}

// chunkDigester hashes a stream as a whole and in ChunkSize pieces.
type chunkDigester struct {
	full   hash.Hash
	chunk  hash.Hash
	filled int
	record []byte
}

func newChunkDigester() *chunkDigester {
	record := make([]byte, chunkRecordHeader, chunkRecordHeader+sha256.Size)
	record[0] = chunkRecordVersion
	return &chunkDigester{full: sha256.New(), chunk: sha256.New(), record: record}
}

func (d *chunkDigester) Write(p []byte) (int, error) {
	written := len(p)
	d.full.Write(p)
	for len(p) > 0 {
		n := min(ChunkSize-d.filled, len(p))
		d.chunk.Write(p[:n])
		d.filled += n
		p = p[n:]
		if d.filled == ChunkSize {
			d.record = d.chunk.Sum(d.record)
			d.chunk.Reset()
			d.filled = 0
		}
	}
	return written, nil
}

// finish returns the whole digest and the chunk-digest record.
func (d *chunkDigester) finish() ([]byte, []byte) {
	if d.filled > 0 {
		d.record = d.chunk.Sum(d.record)
		d.filled = 0
	}
	full := d.full.Sum(nil)
	copy(d.record[1:chunkRecordHeader], full)
	return full, d.record
}

// verifiedBlob serves a blob one verified chunk at a time. Every byte it
// returns comes from the buffer that was hashed, so a change to the file
// after a chunk is checked cannot reach the reader. The size is fixed at
// Open: bytes appended later are never read.
type verifiedBlob struct {
	mu         sync.Mutex
	file       *os.File
	size       int64
	digests    []byte
	recomputed []byte
	offset     int64
	buf        []byte
	pooled     *[]byte
	buffered   int64 // index of the verified chunk held in buf, or -1
	err        error
	closed     bool
}

var chunkBuffers = sync.Pool{New: func() any {
	buf := make([]byte, ChunkSize)
	return &buf
}}

func (b *verifiedBlob) Read(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.usable(); err != nil {
		return 0, err
	}
	if b.offset >= b.size {
		return 0, io.EOF
	}
	if len(p) == 0 {
		return 0, nil
	}
	index := b.offset / ChunkSize
	if err := b.load(index); err != nil {
		return 0, err
	}
	n := copy(p, b.buf[b.offset-index*ChunkSize:])
	b.offset += int64(n)
	return n, nil
}

func (b *verifiedBlob) Seek(offset int64, whence int) (int64, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	var position int64
	switch whence {
	case io.SeekStart:
		position = offset
	case io.SeekCurrent:
		position = b.offset + offset
	case io.SeekEnd:
		position = b.size + offset
	default:
		return 0, errors.New("blob seek: invalid whence")
	}
	if position < 0 || position > b.size {
		return 0, errors.New("blob seek: position out of range")
	}
	b.offset = position
	return position, nil
}

func (b *verifiedBlob) VerifyCurrent() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.usable(); err != nil {
		return err
	}
	if b.offset >= b.size {
		return nil
	}
	return b.load(b.offset / ChunkSize)
}

func (b *verifiedBlob) Err() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.err
}

func (b *verifiedBlob) RecomputedChunkDigests() []byte { return b.recomputed }

func (b *verifiedBlob) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return os.ErrClosed
	}
	b.closed = true
	// Every method checks closed under mu first, so the buffer is never
	// touched again once it is back in the pool.
	if b.pooled != nil {
		chunkBuffers.Put(b.pooled)
		b.pooled = nil
	}
	b.buf = nil
	b.buffered = -1
	return b.file.Close()
}

func (b *verifiedBlob) usable() error {
	if b.closed {
		return os.ErrClosed
	}
	return b.err
}

// load makes buf hold the verified contents of chunk index. A failure is
// sticky: the blob returns it from every later read.
func (b *verifiedBlob) load(index int64) error {
	if index == b.buffered {
		return nil
	}
	b.buffered = -1
	start := index * ChunkSize
	length := min(int64(ChunkSize), b.size-start)
	if b.buf == nil {
		b.pooled = chunkBuffers.Get().(*[]byte)
		b.buf = (*b.pooled)[:0]
	}
	chunk := b.buf[:length]
	n, err := b.file.ReadAt(chunk, start)
	if int64(n) != length {
		if err == nil || errors.Is(err, io.EOF) {
			err = ErrBlobIntegrity
		} else {
			err = errors.Join(ErrBlobIntegrity, err)
		}
		b.err = err
		return err
	}
	sum := sha256.Sum256(chunk)
	if subtle.ConstantTimeCompare(sum[:], b.digests[index*sha256.Size:(index+1)*sha256.Size]) != 1 {
		b.err = ErrBlobIntegrity
		return b.err
	}
	b.buf = chunk
	b.buffered = index
	return nil
}
