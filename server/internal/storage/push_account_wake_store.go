package storage

import (
	"context"
)

const accountPushTargetLimit = 50

// PushTargetsForAccount returns the active push registrations of the
// account's devices that are not revoked, except those of excludeDeviceID
// (empty excludes none). It backs the account-level generic wake sent when a
// recovery claim is created or cancelled (K0-R). The rows carry delivery
// secrets: they stay in memory for the send and are never logged.
func (s *Store) PushTargetsForAccount(ctx context.Context, accountID, excludeDeviceID string) ([]PushTarget, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT ps.id, ps.provider, ps.endpoint, COALESCE(ps.public_key, ''), COALESCE(ps.auth_secret, ''), ps.notification_mode
		FROM push_subscriptions ps
		JOIN accounts a ON a.id = ps.account_id
		LEFT JOIN devices d ON d.id = ps.device_id AND d.account_id = ps.account_id
		WHERE ps.account_id = ? AND a.status = 'active' AND a.deleted_at IS NULL
		  AND ps.provider IN ('webpush', 'fcm', 'apns', 'unifiedpush') AND ps.disabled_at IS NULL
		  AND (ps.device_id IS NULL OR (d.id IS NOT NULL AND d.revoked_at IS NULL))
		  AND (? = '' OR ps.device_id IS NULL OR ps.device_id <> ?)
		ORDER BY ps.id
		LIMIT ?`, accountID, excludeDeviceID, excludeDeviceID, accountPushTargetLimit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var targets []PushTarget
	for rows.Next() {
		var target PushTarget
		if err := rows.Scan(&target.ID, &target.Provider, &target.Endpoint, &target.PublicKey, &target.AuthSecret, &target.NotificationMode); err != nil {
			return nil, err
		}
		targets = append(targets, target)
	}
	return targets, rows.Err()
}
