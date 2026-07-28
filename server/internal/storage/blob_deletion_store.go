package storage

import (
	"context"
	"database/sql"
)

func enqueueBlobDeletion(ctx context.Context, tx *sql.Tx, storageKey string) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO blob_deletion_queue(storage_key, created_at)
		VALUES(?, ?)
		ON CONFLICT(storage_key) DO NOTHING`, storageKey, nowString())
	return err
}

// QueueBlobDeletion durably records a blob whose metadata was not committed.
func (s *Store) QueueBlobDeletion(ctx context.Context, storageKey string) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO blob_deletion_queue(storage_key, created_at)
		VALUES(?, ?)
		ON CONFLICT(storage_key) DO NOTHING`, storageKey, nowString())
	return err
}

func (s *Store) PendingBlobDeletions(ctx context.Context, limit int) ([]string, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT storage_key FROM blob_deletion_queue ORDER BY created_at, storage_key LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	keys := make([]string, 0)
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, err
		}
		keys = append(keys, key)
	}
	return keys, rows.Err()
}

func (s *Store) CompleteBlobDeletion(ctx context.Context, storageKey string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM blob_deletion_queue WHERE storage_key = ?`, storageKey)
	return err
}

func (s *Store) RecordBlobDeletionFailure(ctx context.Context, storageKey string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE blob_deletion_queue SET attempts = attempts + 1, last_attempt_at = ? WHERE storage_key = ?`, nowString(), storageKey)
	return err
}
