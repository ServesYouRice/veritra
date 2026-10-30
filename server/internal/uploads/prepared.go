package uploads

import (
	"context"
	"errors"
	"io"
	"sync"

	"private-messenger/server/internal/domain"
)

// PreparedStore registers a guarded key durably before creating any files.
// Callers must retain PreparedWrite until their metadata commit has finished.
type PreparedStore interface {
	PrepareEncryptedBlob(context.Context, func(string) error) (PreparedWrite, error)
}

type PreparedWrite interface {
	Write(context.Context, io.Reader) (BlobRef, error)
	Close() error
}

var ErrBlobBusy = errors.New("blob has an active prepared writer")

type preparedLocalWrite struct {
	store        *LocalStore
	key          string
	mu           sync.Mutex
	used, closed bool
}

func (s *LocalStore) PrepareEncryptedBlob(ctx context.Context, register func(string) error) (PreparedWrite, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key, err := domain.NewID("blob")
	if err != nil {
		return nil, err
	}
	s.activeMu.Lock()
	if s.active == nil {
		s.active = make(map[string]bool)
	}
	s.active[key] = true
	s.activeMu.Unlock()
	w := &preparedLocalWrite{store: s, key: key}
	if err := register(key); err != nil {
		_ = w.Close()
		return nil, err
	}
	return w, nil
}

func (w *preparedLocalWrite) Write(ctx context.Context, r io.Reader) (BlobRef, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed || w.used {
		return BlobRef{}, errors.New("prepared write already used or closed")
	}
	w.used = true
	return w.store.putEncryptedBlob(ctx, w.key, r)
}

func (w *preparedLocalWrite) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.closed {
		w.store.activeMu.Lock()
		delete(w.store.active, w.key)
		w.store.activeMu.Unlock()
		w.closed = true
	}
	return nil
}
