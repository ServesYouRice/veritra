-- L2-2: devices.last_seen_at keeps only the UTC day. Nothing orders by it;
-- readers (account recovery's activity window) allow a day of slack.
UPDATE devices
SET last_seen_at = substr(last_seen_at, 1, 10) || 'T00:00:00.000000000Z'
WHERE last_seen_at IS NOT NULL;
