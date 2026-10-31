-- The per-account limit on key package claims counts the claimed packages of
-- one device within the last day. The only index on device_key_packages that
-- starts with device_id covers unclaimed rows (WHERE claimed_at IS NULL), so
-- the count would read every row of every device. Claimed rows are pruned
-- after the operational retention, which bounds this index.
CREATE INDEX IF NOT EXISTS idx_device_key_packages_claimed
  ON device_key_packages(device_id, claimed_at)
  WHERE claimed_at IS NOT NULL;
