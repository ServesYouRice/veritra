CREATE TABLE IF NOT EXISTS enrollment_reservations (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('owner', 'register')),
  account_id TEXT NOT NULL UNIQUE,
  device_id TEXT NOT NULL UNIQUE,
  invite_id TEXT REFERENCES invites(id) ON DELETE CASCADE,
  challenge BLOB NOT NULL CHECK(length(challenge) BETWEEN 32 AND 1024),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_enrollment_reservations_expiry
ON enrollment_reservations(expires_at, id)
WHERE consumed_at IS NULL;
