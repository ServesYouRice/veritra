-- T49B: stored blob usage for quota admission.
--
-- enforceBlobQuota used to sum every attachment and backup row inside the
-- single-writer transaction. These counters hold the same sums. Triggers
-- keep them in the same transaction as every insert, delete (including
-- foreign-key cascades) and size or owner change, so admission still reads
-- an exact, serialized total before the new row is written.

CREATE TABLE blob_usage_accounts (
  account_id TEXT PRIMARY KEY,
  size_bytes INTEGER NOT NULL
);

CREATE TABLE blob_usage_instance (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  size_bytes INTEGER NOT NULL
);

-- Backfill from the existing rows.
INSERT INTO blob_usage_accounts(account_id, size_bytes)
SELECT account_id, SUM(size_bytes) FROM (
  SELECT owner_account_id AS account_id, size_bytes FROM attachment_envelopes
  UNION ALL SELECT account_id, size_bytes FROM backup_blobs
) GROUP BY account_id;

INSERT INTO blob_usage_instance(id, size_bytes)
SELECT 1, COALESCE(SUM(size_bytes), 0) FROM (
  SELECT size_bytes FROM attachment_envelopes
  UNION ALL SELECT size_bytes FROM backup_blobs
);

CREATE TRIGGER blob_usage_attachment_insert AFTER INSERT ON attachment_envelopes
BEGIN
  INSERT INTO blob_usage_accounts(account_id, size_bytes) VALUES(NEW.owner_account_id, NEW.size_bytes)
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes + NEW.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_attachment_delete AFTER DELETE ON attachment_envelopes
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes WHERE account_id = OLD.owner_account_id;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_attachment_update AFTER UPDATE OF owner_account_id, size_bytes ON attachment_envelopes
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes WHERE account_id = OLD.owner_account_id;
  INSERT INTO blob_usage_accounts(account_id, size_bytes) VALUES(NEW.owner_account_id, NEW.size_bytes)
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes + NEW.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_backup_insert AFTER INSERT ON backup_blobs
BEGIN
  INSERT INTO blob_usage_accounts(account_id, size_bytes) VALUES(NEW.account_id, NEW.size_bytes)
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes + NEW.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_backup_delete AFTER DELETE ON backup_blobs
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes WHERE account_id = OLD.account_id;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes WHERE id = 1;
END;

CREATE TRIGGER blob_usage_backup_update AFTER UPDATE OF account_id, size_bytes ON backup_blobs
BEGIN
  UPDATE blob_usage_accounts SET size_bytes = size_bytes - OLD.size_bytes WHERE account_id = OLD.account_id;
  INSERT INTO blob_usage_accounts(account_id, size_bytes) VALUES(NEW.account_id, NEW.size_bytes)
    ON CONFLICT(account_id) DO UPDATE SET size_bytes = size_bytes + excluded.size_bytes;
  UPDATE blob_usage_instance SET size_bytes = size_bytes - OLD.size_bytes + NEW.size_bytes WHERE id = 1;
END;
