-- K1 backups share the account's storage quota (owner decision, 2026-11-11;
-- design question 3, option b). Migration 0064 kept kind-1 copies out of
-- blob_usage_accounts; they count again, like attachments and legacy
-- backups, so the account's 512 MiB (ACCOUNT_STORAGE_MIB) covers everything.
-- The instance total always counted every row.
DROP TRIGGER blob_usage_backup_insert;
DROP TRIGGER blob_usage_backup_delete;
DROP TRIGGER blob_usage_backup_update;

CREATE TRIGGER blob_usage_backup_insert AFTER INSERT ON backup_blobs
BEGIN
  INSERT INTO blob_usage_accounts(account_id, size_bytes) VALUES(NEW.account_id, NEW.size_bytes)
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes + NEW.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_backup_delete AFTER DELETE ON backup_blobs
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes
    WHERE account_id = OLD.account_id;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_backup_update AFTER UPDATE OF account_id, size_bytes ON backup_blobs
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes
    WHERE account_id = OLD.account_id;
  INSERT INTO blob_usage_accounts(account_id, size_bytes) VALUES(NEW.account_id, NEW.size_bytes)
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes + NEW.size_bytes WHERE id = 1;
END;

-- Backfill the kind-1 rows 0064 left out of the counters.
INSERT INTO blob_usage_accounts(account_id, size_bytes)
  SELECT account_id, SUM(size_bytes) FROM backup_blobs WHERE kind = 1 GROUP BY account_id
  ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
