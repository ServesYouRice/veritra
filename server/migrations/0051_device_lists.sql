-- L1-2 (D94): each account's signed approved-device list, a hash chain the
-- server stores and serves but cannot forge (docs/designs/L1-approved-device-list.md).
--
-- device_list_versions holds the signed statements, one row per
-- (account, version). The statement bytes are opaque to SQL; the server parses
-- and checks them in Go before inserting. An account's head is its highest
-- version. Accounts that never published a list have no rows: they stay
-- exactly as before.
--
-- device_list_devices is derived from the statements by the same code in the
-- same transaction (never by hand). It lets the honest-server gates ask in SQL
-- whether a device is on its account's head, and keeps the no-return rule
-- (a device id or signing key that left the list never returns) a key check
-- instead of a read of the whole chain. removed_version is NULL while the
-- device is listed.

CREATE TABLE device_list_versions (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  version INTEGER NOT NULL CHECK (version >= 1),
  list_hash BLOB NOT NULL CHECK (length(list_hash) = 32),
  statement BLOB NOT NULL CHECK (length(statement) <= 4096),
  change INTEGER NOT NULL CHECK (change BETWEEN 1 AND 6),
  signer_device_id TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (account_id, version)
) WITHOUT ROWID;

CREATE TABLE device_list_devices (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  signing_key BLOB NOT NULL CHECK (length(signing_key) = 32),
  added_version INTEGER NOT NULL CHECK (added_version >= 1),
  removed_version INTEGER CHECK (removed_version IS NULL OR removed_version > added_version),
  PRIMARY KEY (account_id, device_id),
  UNIQUE (account_id, signing_key)
) WITHOUT ROWID;
