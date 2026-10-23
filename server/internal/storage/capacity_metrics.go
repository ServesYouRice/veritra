package storage

import (
	"context"
	"database/sql"
	"time"

	"private-messenger/server/internal/opmetrics"
)

// Capacity signals for the private /metrics endpoint (card I47). All of them
// are instance-wide totals: no account, conversation, device or storage-key
// identifier is read or returned.

func newWriterAcquireHistogram() *opmetrics.Histogram {
	return opmetrics.NewHistogram(
		time.Millisecond, 5*time.Millisecond, 10*time.Millisecond, 25*time.Millisecond,
		50*time.Millisecond, 100*time.Millisecond, 250*time.Millisecond, 500*time.Millisecond,
		time.Second, 5*time.Second,
	)
}

// PoolStats returns database/sql statistics for the writer pool (one
// connection, so its wait time is the queue for the SQLite writer) and the
// reader pool.
func (s *Store) PoolStats() (writer, reader sql.DBStats) {
	return s.db.writer.Stats(), s.db.reader.Stats()
}

// WriterAcquire returns the distribution of time spent obtaining the writer
// for a transaction.
func (s *Store) WriterAcquire() opmetrics.Snapshot {
	return s.db.writerAcquire.Snapshot()
}

// BlobUsageBytes is the logical size of every stored encrypted attachment
// and backup on the instance, from the counter migration 0031 maintains.
func (s *Store) BlobUsageBytes(ctx context.Context) (int64, error) {
	var total int64
	err := s.db.QueryRowContext(ctx, `SELECT COALESCE((SELECT size_bytes FROM blob_usage_instance WHERE id = 1), 0)`).Scan(&total)
	return total, err
}
