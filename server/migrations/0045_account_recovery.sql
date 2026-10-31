-- K0 recovery enrollment (docs/designs/K0-recovery-enrollment.md, D78, D79).
--
-- Recovery reservations carry the account id they recover (or a stable decoy
-- id), so one account can have several. The rebuild adds the 'recovery' kind
-- and keeps account ids unique only for owner and register reservations.
CREATE TABLE enrollment_reservations_new (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('owner', 'register', 'recovery')),
  account_id TEXT NOT NULL,
  device_id TEXT NOT NULL UNIQUE,
  invite_id TEXT REFERENCES invites(id) ON DELETE CASCADE,
  challenge BLOB NOT NULL CHECK(length(challenge) BETWEEN 32 AND 1024),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT
);
INSERT INTO enrollment_reservations_new(id, kind, account_id, device_id, invite_id, challenge, created_at, expires_at, consumed_at)
SELECT id, kind, account_id, device_id, invite_id, challenge, created_at, expires_at, consumed_at FROM enrollment_reservations;
DROP TABLE enrollment_reservations;
ALTER TABLE enrollment_reservations_new RENAME TO enrollment_reservations;
CREATE UNIQUE INDEX idx_enrollment_reservations_account
ON enrollment_reservations(account_id) WHERE kind <> 'recovery';
CREATE INDEX idx_enrollment_reservations_expiry
ON enrollment_reservations(expires_at, id)
WHERE consumed_at IS NULL;
CREATE INDEX idx_enrollment_reservations_retention
ON enrollment_reservations(expires_at, consumed_at, id);

-- The key behind decoy account ids for usernames that are not active
-- accounts. Setup creates it; an instance set up earlier gets one here.
ALTER TABLE instances ADD COLUMN recovery_decoy_key BLOB CHECK(recovery_decoy_key IS NULL OR length(recovery_decoy_key) = 32);
UPDATE instances SET recovery_decoy_key = randomblob(32) WHERE recovery_decoy_key IS NULL;

-- The recovery key's Ed25519 verification key (rk_auth_pub) and rk_id. The
-- server never holds the recovery key or anything that opens a backup.
CREATE TABLE account_recovery_keys (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  auth_public_key BLOB NOT NULL CHECK(length(auth_public_key) = 32),
  rk_id BLOB NOT NULL CHECK(length(rk_id) = 16),
  created_at TEXT NOT NULL
);

-- A claimed recovery waits here until ready_at, then completion inserts the
-- device. verified_* are the credentials the claim proved; completion still
-- requires them to be current.
CREATE TABLE account_recovery_requests (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL UNIQUE,
  device_name TEXT NOT NULL,
  key_package BLOB NOT NULL,
  signing_key BLOB NOT NULL CHECK(length(signing_key) = 32),
  device_auth_hash TEXT NOT NULL CHECK(length(device_auth_hash) = 64),
  claim_token_hash TEXT NOT NULL UNIQUE CHECK(length(claim_token_hash) = 64),
  verified_password_hash TEXT NOT NULL,
  verified_auth_key BLOB NOT NULL CHECK(length(verified_auth_key) = 32),
  state TEXT NOT NULL CHECK(state IN ('waiting', 'completed', 'cancelled', 'expired')),
  created_at TEXT NOT NULL,
  ready_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  cancelled_by TEXT,
  completed_at TEXT
);
CREATE UNIQUE INDEX idx_account_recovery_requests_waiting
ON account_recovery_requests(account_id) WHERE state = 'waiting';
CREATE INDEX idx_account_recovery_requests_retention
ON account_recovery_requests(expires_at, id);

-- D79: right-password-wrong-recovery-key attempts per account (or decoy) id
-- and UTC day. No foreign key, so decoy ids count too.
CREATE TABLE recovery_attempts (
  account_id TEXT NOT NULL,
  day TEXT NOT NULL,
  failures INTEGER NOT NULL DEFAULT 0 CHECK(failures >= 0),
  leak_notified INTEGER NOT NULL DEFAULT 0 CHECK(leak_notified IN (0, 1)),
  PRIMARY KEY(account_id, day)
);
CREATE INDEX idx_recovery_attempts_day ON recovery_attempts(day);
