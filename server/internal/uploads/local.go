package uploads

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
)

type LocalStore struct {
	root string
}

func NewLocalStore(root string) (*LocalStore, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	return &LocalStore{root: root}, nil
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
	defer file.Close()

	hash := sha256.New()
	written, err := io.Copy(file, io.TeeReader(r, hash))
	if err != nil {
		_ = os.Remove(tmp)
		return "", "", 0, err
	}
	if err := ctx.Err(); err != nil {
		_ = os.Remove(tmp)
		return "", "", 0, err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(tmp)
		return "", "", 0, err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return "", "", 0, err
	}
	return id, hex.EncodeToString(hash.Sum(nil)), written, nil
}

func (s *LocalStore) Open(storageKey string) (io.ReadCloser, error) {
	return os.Open(filepath.Join(s.root, filepath.Base(storageKey)))
}

func (s *LocalStore) Delete(ctx context.Context, storageKey string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	err := os.Remove(filepath.Join(s.root, filepath.Base(storageKey)))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
