-- Retention scans begin with expiry/cleanup timestamps, not account/device
-- ownership. Keep these narrow indexes aligned with the bounded sweeper.
CREATE INDEX IF NOT EXISTS idx_device_key_packages_retention
ON device_key_packages(expires_at, claimed_at, id);

CREATE INDEX IF NOT EXISTS idx_enrollment_reservations_retention
ON enrollment_reservations(expires_at, consumed_at, id);
