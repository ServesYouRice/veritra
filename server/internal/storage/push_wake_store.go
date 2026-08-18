package storage

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"private-messenger/server/internal/domain"
)

const (
	pushWakeJobTTL    = 24 * time.Hour
	pushWakeBatchLimit = 64
)

// PushWakeJob contains the routing data needed to send a generic wake. It
// intentionally does not contain message content, ciphertext, or push secrets
// beyond the in-memory target resolved from the subscription row at claim time.
type PushWakeJob struct {
	EventID            int64
	RecipientAccountID string
	SubscriptionID     string
	Provider           string
	Endpoint           string
	PublicKey          string
	AuthSecret         string
	Attempts            int
	LeaseToken         string
}

// PushWakeBacklog is aggregate-only operational state for one provider.
type PushWakeBacklog struct {
	Provider string
	Rows     int64
}

func enqueuePushWakeJobs(ctx context.Context, tx *sql.Tx, eventID int64, conversationID, senderAccountID string, createdAt, expiresAt string) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO push_wake_jobs(sync_event_id, conversation_id, sender_account_id, recipient_account_id, subscription_id, created_at, next_attempt_at, expires_at)
		SELECT ?, ?, ?, ps.account_id, ps.id, ?, ?, ?
		FROM push_subscriptions ps
		JOIN memberships m ON m.account_id = ps.account_id
		LEFT JOIN devices d ON d.id = ps.device_id AND d.account_id = ps.account_id
		WHERE m.conversation_id = ?
		  AND ps.account_id <> ?
		  AND ps.provider IN ('webpush', 'fcm', 'apns')
		  AND ps.disabled_at IS NULL
		  AND (ps.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))
		  AND NOT EXISTS (
			SELECT 1 FROM account_blocks b
			WHERE b.blocker_account_id = ps.account_id AND b.blocked_account_id = ?
		  )
		  AND NOT EXISTS (
			SELECT 1 FROM conversation_notification_preferences p
			WHERE p.account_id = ps.account_id AND p.conversation_id = ? AND p.muted = 1
		  )
		ON CONFLICT(sync_event_id, recipient_account_id, subscription_id) DO NOTHING`,
		eventID, conversationID, senderAccountID, createdAt, createdAt, expiresAt,
		conversationID, senderAccountID, senderAccountID, conversationID)
	return err
}

// ClaimPushWakeJobs leases a bounded batch for one provider. Expired leases
// are reclaimable after a process crash; expired jobs are removed and counted
// as abandoned for provider-level metrics.
func (s *Store) ClaimPushWakeJobs(ctx context.Context, provider string, limit int, now time.Time, leaseDuration time.Duration) ([]PushWakeJob, int64, error) {
	if limit <= 0 || limit > pushWakeBatchLimit {
		limit = pushWakeBatchLimit
	}
	if leaseDuration <= 0 {
		leaseDuration = 30 * time.Second
	}
	now = now.UTC()
	nowText := formatTime(now)
	leaseText := formatTime(now.Add(leaseDuration))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		DELETE FROM push_wake_jobs
		WHERE rowid IN (
			SELECT w.rowid FROM push_wake_jobs w
			JOIN push_subscriptions ps ON ps.id = w.subscription_id AND ps.account_id = w.recipient_account_id
			WHERE ps.provider = ? AND w.expires_at <= ?
			ORDER BY w.expires_at, w.sync_event_id, w.subscription_id LIMIT ?
		)`, provider, nowText, pushWakeBatchLimit)
	if err != nil {
		return nil, 0, err
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM push_wake_jobs
		WHERE rowid IN (
			SELECT w.rowid FROM push_wake_jobs w
			WHERE EXISTS (
				SELECT 1 FROM push_subscriptions ps
				WHERE ps.id = w.subscription_id AND ps.disabled_at IS NOT NULL
			) AND EXISTS (
				SELECT 1 FROM push_subscriptions ps2
				WHERE ps2.id = w.subscription_id AND ps2.provider = ?
			) ORDER BY w.expires_at, w.sync_event_id, w.subscription_id LIMIT ?
		)`, provider, pushWakeBatchLimit); err != nil {
		return nil, 0, err
	}
	abandoned, err := result.RowsAffected()
	if err != nil {
		return nil, 0, err
	}
	rows, err := tx.QueryContext(ctx, `
		SELECT w.sync_event_id, w.recipient_account_id, w.subscription_id
		FROM push_wake_jobs w
		JOIN push_subscriptions ps ON ps.id = w.subscription_id AND ps.account_id = w.recipient_account_id
		JOIN memberships m ON m.conversation_id = w.conversation_id AND m.account_id = w.recipient_account_id
		LEFT JOIN devices d ON d.id = ps.device_id AND d.account_id = ps.account_id
		WHERE ps.provider = ?
		  AND ps.disabled_at IS NULL
		  AND (ps.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))
		  AND NOT EXISTS (
			SELECT 1 FROM account_blocks b
			WHERE b.blocker_account_id = w.recipient_account_id AND b.blocked_account_id = w.sender_account_id
		  )
		  AND NOT EXISTS (
			SELECT 1 FROM conversation_notification_preferences p
			WHERE p.account_id = w.recipient_account_id AND p.conversation_id = w.conversation_id AND p.muted = 1
		  )
		  AND w.expires_at > ?
		  AND w.next_attempt_at <= ?
		  AND (w.lease_expires_at IS NULL OR w.lease_expires_at <= ?)
		ORDER BY w.next_attempt_at, w.sync_event_id, w.subscription_id
		LIMIT ?`, provider, nowText, nowText, nowText, limit)
	if err != nil {
		return nil, 0, err
	}
	type key struct {
		eventID            int64
		recipientAccountID string
		subscriptionID     string
	}
	keys := make([]key, 0, limit)
	for rows.Next() {
		var item key
		if err := rows.Scan(&item.eventID, &item.recipientAccountID, &item.subscriptionID); err != nil {
			rows.Close()
			return nil, 0, err
		}
		keys = append(keys, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, 0, err
	}
	if err := rows.Close(); err != nil {
		return nil, 0, err
	}
	if len(keys) == 0 {
		if err := tx.Commit(); err != nil {
			return nil, 0, err
		}
		return nil, abandoned, nil
	}
	leaseToken, err := domain.NewID("wake")
	if err != nil {
		return nil, 0, err
	}
	for _, item := range keys {
		if _, err := tx.ExecContext(ctx, `
			UPDATE push_wake_jobs
			SET lease_token = ?, lease_expires_at = ?, attempts = attempts + 1
			WHERE sync_event_id = ? AND recipient_account_id = ? AND subscription_id = ?
			  AND (lease_expires_at IS NULL OR lease_expires_at <= ?)
			  AND next_attempt_at <= ? AND expires_at > ?`,
			leaseToken, leaseText, item.eventID, item.recipientAccountID, item.subscriptionID, nowText, nowText, nowText); err != nil {
			return nil, 0, err
		}
	}
	claimedRows, err := tx.QueryContext(ctx, `
		SELECT w.sync_event_id, w.recipient_account_id, w.subscription_id,
		       ps.provider, ps.endpoint, COALESCE(ps.public_key, ''), COALESCE(ps.auth_secret, ''),
		       w.attempts
		FROM push_wake_jobs w
		JOIN push_subscriptions ps ON ps.id = w.subscription_id AND ps.account_id = w.recipient_account_id
		WHERE w.lease_token = ? AND ps.provider = ? AND ps.disabled_at IS NULL
		ORDER BY w.sync_event_id, w.subscription_id`, leaseToken, provider)
	if err != nil {
		return nil, 0, err
	}
	jobs := make([]PushWakeJob, 0, len(keys))
	for claimedRows.Next() {
		var job PushWakeJob
		if err := claimedRows.Scan(&job.EventID, &job.RecipientAccountID, &job.SubscriptionID, &job.Provider, &job.Endpoint, &job.PublicKey, &job.AuthSecret, &job.Attempts); err != nil {
			claimedRows.Close()
			return nil, 0, err
		}
		job.LeaseToken = leaseToken
		jobs = append(jobs, job)
	}
	if err := claimedRows.Err(); err != nil {
		claimedRows.Close()
		return nil, 0, err
	}
	if err := claimedRows.Close(); err != nil {
		return nil, 0, err
	}
	if err := tx.Commit(); err != nil {
		return nil, 0, err
	}
	return jobs, abandoned, nil
}

// RefreshPushWakeJob rechecks authorization and resolves the current
// subscription credentials immediately before a provider request. This avoids
// waking a recipient who muted/blocked the sender or whose device was revoked
// after enqueue, and makes credential rotation visible to the send attempt.
func (s *Store) RefreshPushWakeJob(ctx context.Context, job PushWakeJob, now time.Time) (PushWakeJob, error) {
	var fresh PushWakeJob
	err := s.db.QueryRowContext(ctx, `
		SELECT w.sync_event_id, w.recipient_account_id, w.subscription_id,
		       ps.provider, ps.endpoint, COALESCE(ps.public_key, ''), COALESCE(ps.auth_secret, ''),
		       w.attempts
		FROM push_wake_jobs w
		JOIN push_subscriptions ps ON ps.id = w.subscription_id AND ps.account_id = w.recipient_account_id
		JOIN memberships m ON m.conversation_id = w.conversation_id AND m.account_id = w.recipient_account_id
		LEFT JOIN devices d ON d.id = ps.device_id AND d.account_id = ps.account_id
		WHERE w.sync_event_id = ? AND w.recipient_account_id = ? AND w.subscription_id = ?
		  AND w.lease_token = ? AND w.expires_at > ?
		  AND ps.disabled_at IS NULL
		  AND (ps.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))
		  AND NOT EXISTS (
			SELECT 1 FROM account_blocks b
			WHERE b.blocker_account_id = w.recipient_account_id AND b.blocked_account_id = w.sender_account_id
		  )
		  AND NOT EXISTS (
			SELECT 1 FROM conversation_notification_preferences p
			WHERE p.account_id = w.recipient_account_id AND p.conversation_id = w.conversation_id AND p.muted = 1
		  )`,
		job.EventID, job.RecipientAccountID, job.SubscriptionID, job.LeaseToken, formatTime(now.UTC())).Scan(
		&fresh.EventID, &fresh.RecipientAccountID, &fresh.SubscriptionID, &fresh.Provider, &fresh.Endpoint,
		&fresh.PublicKey, &fresh.AuthSecret, &fresh.Attempts)
	if errors.Is(err, sql.ErrNoRows) {
		return PushWakeJob{}, ErrNotFound
	}
	if err != nil {
		return PushWakeJob{}, err
	}
	fresh.LeaseToken = job.LeaseToken
	return fresh, nil
}

func (s *Store) DropPushWakeJob(ctx context.Context, job PushWakeJob) error {
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM push_wake_jobs
		WHERE sync_event_id = ? AND recipient_account_id = ? AND subscription_id = ? AND lease_token = ?`,
		job.EventID, job.RecipientAccountID, job.SubscriptionID, job.LeaseToken)
	return err
}

func (s *Store) CompletePushWakeJob(ctx context.Context, job PushWakeJob) error {
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM push_wake_jobs
		WHERE sync_event_id = ? AND recipient_account_id = ? AND subscription_id = ? AND lease_token = ?`,
		job.EventID, job.RecipientAccountID, job.SubscriptionID, job.LeaseToken)
	return err
}

func (s *Store) RetryPushWakeJob(ctx context.Context, job PushWakeJob, nextAttemptAt, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE push_wake_jobs
		SET next_attempt_at = ?, lease_token = NULL, lease_expires_at = NULL
		WHERE sync_event_id = ? AND recipient_account_id = ? AND subscription_id = ?
		  AND lease_token = ? AND expires_at > ?`,
		formatTime(nextAttemptAt.UTC()), job.EventID, job.RecipientAccountID, job.SubscriptionID, job.LeaseToken, formatTime(now.UTC()))
	return err
}

// RetirePushWakeSubscription removes all queued work for a provider target
// after the provider reports that its subscription is gone.
func (s *Store) RetirePushWakeSubscription(ctx context.Context, job PushWakeJob) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := nowString()
	result, err := tx.ExecContext(ctx, `
		UPDATE push_subscriptions
		SET disabled_at = COALESCE(disabled_at, ?)
		WHERE id = ? AND provider = ? AND endpoint = ?
		  AND COALESCE(public_key, '') = ? AND COALESCE(auth_secret, '') = ?`,
		now, job.SubscriptionID, job.Provider, job.Endpoint, job.PublicKey, job.AuthSecret)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		_, err := tx.ExecContext(ctx, `
			UPDATE push_wake_jobs SET next_attempt_at = ?, lease_token = NULL, lease_expires_at = NULL
			WHERE sync_event_id = ? AND recipient_account_id = ? AND subscription_id = ? AND lease_token = ?`,
			now, job.EventID, job.RecipientAccountID, job.SubscriptionID, job.LeaseToken)
		if err != nil {
			return err
		}
		return tx.Commit()
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM push_wake_jobs WHERE subscription_id = ?`, job.SubscriptionID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) PushWakeBacklog(ctx context.Context, now time.Time) ([]PushWakeBacklog, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT ps.provider, COUNT(*)
		FROM push_wake_jobs w
		JOIN push_subscriptions ps ON ps.id = w.subscription_id AND ps.account_id = w.recipient_account_id
		WHERE w.expires_at > ? AND ps.disabled_at IS NULL
		GROUP BY ps.provider ORDER BY ps.provider`, formatTime(now.UTC()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	backlog := make([]PushWakeBacklog, 0, 3)
	for rows.Next() {
		var item PushWakeBacklog
		if err := rows.Scan(&item.Provider, &item.Rows); err != nil {
			return nil, err
		}
		backlog = append(backlog, item)
	}
	return backlog, rows.Err()
}

func (s *Store) PruneExpiredPushWakeJobs(ctx context.Context, now time.Time, limit int) (int64, error) {
	if limit <= 0 || limit > 500 {
		limit = 500
	}
	result, err := s.db.ExecContext(ctx, `
		DELETE FROM push_wake_jobs
		WHERE rowid IN (
			SELECT rowid FROM push_wake_jobs WHERE expires_at <= ? ORDER BY expires_at, sync_event_id, subscription_id LIMIT ?
		)`, formatTime(now.UTC()), limit)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}
