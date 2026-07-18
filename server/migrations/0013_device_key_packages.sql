CREATE TABLE IF NOT EXISTS device_key_packages (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  key_package BLOB NOT NULL,
  ciphersuite TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  claimed_at TEXT,
  claimed_by_device_id TEXT REFERENCES devices(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_device_key_packages_available
ON device_key_packages(device_id, expires_at, created_at, id)
WHERE claimed_at IS NULL;

INSERT INTO device_key_packages(
  id, device_id, key_package, ciphersuite, created_at, expires_at
)
SELECT
  'kp_' || lower(hex(randomblob(16))),
  id,
  key_package,
  'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
  created_at,
  strftime('%Y-%m-%dT%H:%M:%fZ', created_at, '+30 days')
FROM devices
WHERE length(key_package) > 0;
