-- B7 passkeys (docs/designs/B7-passkeys.md). Only adds tables: an older
-- binary ignores them and passkey users fall back to their password.
CREATE TABLE passkey_user_handles (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  user_handle BLOB NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);
CREATE TABLE passkey_credentials (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  credential_id BLOB NOT NULL UNIQUE,
  public_key BLOB NOT NULL,
  algorithm INTEGER NOT NULL,
  sign_count INTEGER NOT NULL,
  backup_eligible INTEGER NOT NULL,
  backup_state INTEGER NOT NULL,
  transports TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT
);
CREATE INDEX idx_passkey_credentials_account ON passkey_credentials(account_id);
CREATE TABLE passkey_ceremonies (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('register', 'login')),
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  session_data BLOB NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX idx_passkey_ceremonies_device ON passkey_ceremonies(device_id, created_at);
CREATE INDEX idx_passkey_ceremonies_expiry ON passkey_ceremonies(expires_at);
