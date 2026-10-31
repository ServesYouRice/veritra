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

// OperationalRowRetention is how long PruneOperationalRows keeps revoked,
// consumed, claimed and disabled operational rows before removing them.
const OperationalRowRetention = 30 * 24 * time.Hour

// RetentionBacklog counts rows the retention sweep can prune now. Each entry
// mirrors one prune predicate exactly, so a completed sweep reads zero; rows
// still inside their grace period are not backlog. The oldest age is measured
// from when a row became prunable (its timestamp plus the grace period).
//
// Sync events are only counted when the sync-event retention is known: use
// RetentionBacklogWithSyncRetention for that. This form leaves them out.
func (s *Store) RetentionBacklog(ctx context.Context, now time.Time) (RetentionBacklog, error) {
	return s.RetentionBacklogWithSyncRetention(ctx, now, 0)
}

// OrphanedAttachmentGrace is how long an uploaded attachment may stay unlinked
// to a message before PruneExpiredContent reaps it.
const OrphanedAttachmentGrace = 24 * time.Hour

// RetentionBacklogWithSyncRetention is RetentionBacklog that also counts the
// sync events PruneSyncEvents removes once they are older than syncRetention
// (the sweeper's configured cutoff, passed in so storage does not hold a copy
// of it). A syncRetention of zero or less leaves sync events out.
func (s *Store) RetentionBacklogWithSyncRetention(ctx context.Context, now time.Time, syncRetention time.Duration) (RetentionBacklog, error) {
	current := formatTime(now.UTC())
	cutoff := formatTime(now.UTC().Add(-OperationalRowRetention))
	grace := OperationalRowRetention
	orphanCutoff := formatTime(now.UTC().Add(-OrphanedAttachmentGrace))
	queries := []struct {
		table string
		where string
		since string
		args  []interface{}
		grace time.Duration
	}{
		// PruneExpiredContent and PruneCallSessions.
		{"message_envelopes", `expires_at IS NOT NULL AND expires_at <= ?`, `expires_at`, []interface{}{current}, 0},
		// PruneExpiredContent also reaps attachments no message links, after a
		// grace period.
		{"attachment_envelopes", `created_at < ? AND NOT EXISTS (SELECT 1 FROM message_attachments ma WHERE ma.attachment_id = attachment_envelopes.id)`, `created_at`, []interface{}{orphanCutoff}, OrphanedAttachmentGrace},
		{"call_sessions", `expires_at IS NOT NULL AND expires_at <= ?`, `expires_at`, []interface{}{current}, 0},
		// PruneOperationalRows.
		{"sessions", `expires_at <= ?`, `expires_at`, []interface{}{current}, 0},
		{"invites", `(expires_at IS NOT NULL AND expires_at < ?) OR (revoked_at IS NOT NULL AND revoked_at < ?)`, `MIN(COALESCE(expires_at, revoked_at), COALESCE(revoked_at, expires_at))`, []interface{}{cutoff, cutoff}, grace},
		{"device_links", `expires_at < ? AND state IN ('consumed', 'revoked')`, `expires_at`, []interface{}{cutoff}, grace},
		{"device_links_v3", `COALESCE(transfer_expires_at,expires_at) < ?`, `COALESCE(transfer_expires_at,expires_at)`, []interface{}{cutoff}, grace},
		{"device_history_upload_intents", `expires_at <= ?`, `expires_at`, []interface{}{current}, 0},
		{"device_history_transfers", `state='active' AND expires_at <= ?`, `expires_at`, []interface{}{current}, 0},
		{"enrollment_reservations", `expires_at < ?`, `expires_at`, []interface{}{current}, 0},
		{"enrollment_reservations", `expires_at >= ? AND consumed_at IS NOT NULL AND consumed_at < ?`, `consumed_at`, []interface{}{current, cutoff}, grace},
		{"push_subscriptions", `disabled_at IS NOT NULL AND disabled_at < ?`, `disabled_at`, []interface{}{cutoff}, grace},
		{"device_key_packages", `expires_at < ?`, `expires_at`, []interface{}{current}, 0},
		{"device_key_packages", `expires_at >= ? AND claimed_at IS NOT NULL AND claimed_at < ?`, `claimed_at`, []interface{}{current, cutoff}, grace},
		// reconcileBlobDeletions.
		{"blob_deletion_queue", `1 = 1`, `created_at`, nil, 0},
	}
	if syncRetention > 0 {
		// PruneSyncEvents.
		queries = append(queries, struct {
			table string
			where string
			since string
			args  []interface{}
			grace time.Duration
		}{"sync_events", `created_at < ?`, `created_at`, []interface{}{formatTime(now.UTC().Add(-syncRetention))}, syncRetention})
	}
	var result RetentionBacklog
	var oldest time.Time
	for _, query := range queries {
		var count int64
		var raw sql.NullString
		row := s.db.QueryRowContext(ctx, `SELECT COUNT(*), MIN(`+query.since+`) FROM `+query.table+` WHERE `+query.where, query.args...)
		if err := row.Scan(&count, &raw); err != nil {
			return RetentionBacklog{}, err
		}
		result.Rows += count
		if raw.Valid && raw.String != "" {
			candidate := parseTime(raw.String).Add(query.grace)
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
