package storage

import (
	"context"
	"database/sql"
	"time"
)

// RetentionBacklog is deliberately aggregate-only: it contains no account,
// message, attachment or storage-key identifiers.
type RetentionBacklog struct {
	Rows            int64
	OldestAgeSecond int64
}

func (s *Store) RetentionBacklog(ctx context.Context, now time.Time) (RetentionBacklog, error) {
	cutoff := formatTime(now.UTC())
	queries := []struct {
		count  string
		oldest string
		args   []interface{}
	}{
		{`SELECT COUNT(*) FROM message_envelopes WHERE expires_at IS NOT NULL AND expires_at <= ?`, `SELECT MIN(expires_at) FROM message_envelopes WHERE expires_at IS NOT NULL AND expires_at <= ?`, []interface{}{cutoff}},
		{`SELECT COUNT(*) FROM call_sessions WHERE expires_at IS NOT NULL AND expires_at <= ?`, `SELECT MIN(expires_at) FROM call_sessions WHERE expires_at IS NOT NULL AND expires_at <= ?`, []interface{}{cutoff}},
		{`SELECT COUNT(*) FROM sessions WHERE expires_at <= ?`, `SELECT MIN(expires_at) FROM sessions WHERE expires_at <= ?`, []interface{}{cutoff}},
		{`SELECT COUNT(*) FROM invites WHERE (expires_at IS NOT NULL AND expires_at <= ?) OR (revoked_at IS NOT NULL AND revoked_at <= ?)`, `SELECT MIN(COALESCE(revoked_at, expires_at)) FROM invites WHERE (expires_at IS NOT NULL AND expires_at <= ?) OR (revoked_at IS NOT NULL AND revoked_at <= ?)`, []interface{}{cutoff, cutoff}},
		{`SELECT COUNT(*) FROM device_links WHERE expires_at <= ? AND state IN ('consumed', 'revoked')`, `SELECT MIN(expires_at) FROM device_links WHERE expires_at <= ? AND state IN ('consumed', 'revoked')`, []interface{}{cutoff}},
		{`SELECT COUNT(*) FROM enrollment_reservations WHERE expires_at <= ? OR (consumed_at IS NOT NULL AND consumed_at <= ?)`, `SELECT MIN(COALESCE(consumed_at, expires_at)) FROM enrollment_reservations WHERE expires_at <= ? OR (consumed_at IS NOT NULL AND consumed_at <= ?)`, []interface{}{cutoff, cutoff}},
		{`SELECT COUNT(*) FROM push_subscriptions WHERE disabled_at IS NOT NULL AND disabled_at <= ?`, `SELECT MIN(disabled_at) FROM push_subscriptions WHERE disabled_at IS NOT NULL AND disabled_at <= ?`, []interface{}{cutoff}},
		{`SELECT COUNT(*) FROM device_key_packages WHERE expires_at <= ? OR (claimed_at IS NOT NULL AND claimed_at <= ?)`, `SELECT MIN(COALESCE(claimed_at, expires_at)) FROM device_key_packages WHERE expires_at <= ? OR (claimed_at IS NOT NULL AND claimed_at <= ?)`, []interface{}{cutoff, cutoff}},
		{`SELECT COUNT(*) FROM blob_deletion_queue`, `SELECT MIN(created_at) FROM blob_deletion_queue`, nil},
	}
	var result RetentionBacklog
	var oldest time.Time
	for _, query := range queries {
		var count int64
		if err := s.db.QueryRowContext(ctx, query.count, query.args...).Scan(&count); err != nil {
			return RetentionBacklog{}, err
		}
		result.Rows += count
		var raw sql.NullString
		if err := s.db.QueryRowContext(ctx, query.oldest, query.args...).Scan(&raw); err != nil {
			return RetentionBacklog{}, err
		}
		if raw.Valid && raw.String != "" {
			candidate := parseTime(raw.String)
			if oldest.IsZero() || candidate.Before(oldest) {
				oldest = candidate
			}
		}
	}
	if !oldest.IsZero() && now.After(oldest) {
		result.OldestAgeSecond = int64(now.Sub(oldest).Seconds())
	}
	return result, nil
}
