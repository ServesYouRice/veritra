-- K1-2 automatic backups (docs/designs/K1-automatic-backups.md, D91).
--
-- A K1 copy (kind 1) is sealed to the account's recovery key and never
-- expires. Each device keeps one current copy; an upload marks the one before
-- superseded, and it stays downloadable for 24 hours. Legacy I45/VBK2 rows
-- are kind 0 and keep their recovery-token columns until K1-6.
ALTER TABLE backup_blobs ADD COLUMN kind INTEGER NOT NULL DEFAULT 0 CHECK(kind IN (0, 1));
ALTER TABLE backup_blobs ADD COLUMN rk_id BLOB CHECK(rk_id IS NULL OR length(rk_id) = 16);
ALTER TABLE backup_blobs ADD COLUMN counter INTEGER CHECK(counter IS NULL OR counter > 0);
ALTER TABLE backup_blobs ADD COLUMN superseded_at TEXT;

CREATE INDEX idx_backup_blobs_device_current
ON backup_blobs(account_id, device_id, superseded_at);

-- Each device's highest K1 counter, kept when its copies are deleted (a
-- recovery-key swap, a delete, the prune), so a counter is never accepted
-- twice.
CREATE TABLE k1_backup_counters (
  device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  counter INTEGER NOT NULL CHECK(counter > 0)
);

-- A K1 row always names its device, key and counter: the swap and the
-- prune compare rk_id, which a NULL would slip past.
CREATE TRIGGER backup_blobs_k1_fields BEFORE INSERT ON backup_blobs
WHEN NEW.kind = 1 AND (NEW.rk_id IS NULL OR NEW.counter IS NULL OR NEW.device_id IS NULL)
BEGIN
  SELECT RAISE(ABORT, 'k1 backup needs device_id, rk_id and counter');
END;

-- K1 copies have their own allowance (D91: 2 x 64 MiB), so they leave the
-- account's attachment quota. The instance total still counts every row.
-- Existing rows are all kind 0, so the T49B backfill stays exact.
DROP TRIGGER blob_usage_backup_insert;
DROP TRIGGER blob_usage_backup_delete;
DROP TRIGGER blob_usage_backup_update;

CREATE TRIGGER blob_usage_backup_insert AFTER INSERT ON backup_blobs
BEGIN
  INSERT INTO blob_usage_accounts(account_id, size_bytes)
    SELECT NEW.account_id, NEW.size_bytes WHERE NEW.kind = 0
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes + NEW.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_backup_delete AFTER DELETE ON backup_blobs
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes
    WHERE account_id = OLD.account_id AND OLD.kind = 0;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_backup_update AFTER UPDATE OF account_id, size_bytes, kind ON backup_blobs
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes
    WHERE account_id = OLD.account_id AND OLD.kind = 0;
  INSERT INTO blob_usage_accounts(account_id, size_bytes)
    SELECT NEW.account_id, NEW.size_bytes WHERE NEW.kind = 0
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes + NEW.size_bytes WHERE id = 1;
END;
