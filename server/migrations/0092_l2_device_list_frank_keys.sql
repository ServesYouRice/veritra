-- L2-3 (DV franking): approved-device list format 2 carries each device's
-- X25519 franking key, and change 7 lets a listed device set its own, once
-- (docs/designs/L1-approved-device-list.md, "Format 2"; docs/crypto.md,
-- "Franking a sealed message"). The keys stay inside the signed statements;
-- the server reads them from there and stores no copy. SQLite cannot widen a
-- CHECK in place, so device_list_versions is rebuilt with change 1..7;
-- nothing references it.
CREATE TABLE device_list_versions_l2 (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  version INTEGER NOT NULL CHECK (version >= 1),
  list_hash BLOB NOT NULL CHECK (length(list_hash) = 32),
  statement BLOB NOT NULL CHECK (length(statement) <= 4096),
  change INTEGER NOT NULL CHECK (change BETWEEN 1 AND 7),
  signer_device_id TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (account_id, version)
) WITHOUT ROWID;
INSERT INTO device_list_versions_l2(account_id, version, list_hash, statement, change, signer_device_id, created_at)
  SELECT account_id, version, list_hash, statement, change, signer_device_id, created_at FROM device_list_versions;
DROP TABLE device_list_versions;
ALTER TABLE device_list_versions_l2 RENAME TO device_list_versions;
