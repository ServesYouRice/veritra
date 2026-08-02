package uploads

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
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

func (s *LocalStore) PutEncryptedBlob(ctx context.Context, r io.Reader) (storageKey string, sha256Hex string, size int64, err error) {
	id, err := domain.NewID("blob")
	if err != nil {
		return "", "", 0, err
	}
	path := filepath.Join(s.root, id)
	tmp := path + ".tmp"
	file, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", "", 0, err
	}
	closed := false
	defer func() {
		if !closed {
			_ = file.Close()
		}
	}()

	hash := sha256.New()
	written, err := io.Copy(file, io.TeeReader(&contextReader{ctx: ctx, reader: r}, hash))
	if err != nil {
		_ = file.Close()
		closed = true
		_ = s.remove(tmp)
		return "", "", 0, err
	}
	if err := s.syncFile(file); err != nil {
		_ = file.Close()
		closed = true
		_ = s.remove(tmp)
		return "", "", 0, err
	}
	if err := file.Close(); err != nil {
		closed = true
		_ = s.remove(tmp)
		return "", "", 0, err
	}
	closed = true
	if err := s.rename(tmp, path); err != nil {
		_ = s.remove(tmp)
		return "", "", 0, err
	}
	if err := s.syncDirectory(s.root); err != nil {
		_ = s.remove(path)
		_ = s.syncDirectory(s.root)
		return "", "", 0, err
	}
	return id, hex.EncodeToString(hash.Sum(nil)), written, nil
}

func (s *LocalStore) Open(ctx context.Context, storageKey, expectedSHA256 string, expectedSize int64) (ReadSeekCloser, error) {
	path, err := s.path(storageKey)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	fail := func(cause error) (ReadSeekCloser, error) {
		_ = file.Close()
		return nil, cause
	}
	info, err := file.Stat()
	if err != nil {
		return fail(err)
	}
	if !info.Mode().IsRegular() || expectedSize < 0 || info.Size() != expectedSize {
		return fail(ErrBlobIntegrity)
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, &contextReader{ctx: ctx, reader: file}); err != nil {
		return fail(err)
	}
	expected, err := hex.DecodeString(expectedSHA256)
	if err != nil || len(expected) != sha256.Size || subtle.ConstantTimeCompare(hash.Sum(nil), expected) != 1 {
		return fail(ErrBlobIntegrity)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return fail(err)
	}
	return file, nil
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
