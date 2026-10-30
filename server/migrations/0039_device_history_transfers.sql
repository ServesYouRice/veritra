ALTER TABLE device_links_v3 ADD COLUMN history_cancelled_at TEXT;
CREATE TABLE device_history_transfers (
 link_id TEXT PRIMARY KEY REFERENCES device_links_v3(id) ON DELETE CASCADE,
 transfer_id TEXT NOT NULL UNIQUE,
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 source_device_id TEXT NOT NULL,
 recipient_device_id TEXT NOT NULL,
 claim_request_hash TEXT NOT NULL,
 transcript_hash BLOB NOT NULL,
 ciphertext_sha256 TEXT NOT NULL,
 size_bytes INTEGER NOT NULL CHECK(size_bytes BETWEEN 1 AND 104857600),
 handoff BLOB,
 handoff_sha256 TEXT NOT NULL,
 storage_key TEXT UNIQUE,
 chunk_digests BLOB,
 state TEXT NOT NULL CHECK(state IN ('active','acknowledged','cancelled','expired')),
 created_at TEXT NOT NULL,
 expires_at TEXT NOT NULL,
 terminal_at TEXT,
 CHECK((state='active' AND storage_key IS NOT NULL AND handoff IS NOT NULL) OR
       (state<>'active' AND storage_key IS NULL AND handoff IS NULL AND chunk_digests IS NULL))
);
CREATE INDEX idx_history_transfer_deadline ON device_history_transfers(state,expires_at,link_id);

CREATE TABLE device_history_upload_intents (
 storage_key TEXT PRIMARY KEY,
 link_id TEXT NOT NULL UNIQUE REFERENCES device_links_v3(id) ON DELETE CASCADE,
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 transfer_id TEXT NOT NULL,
 metadata_sha256 TEXT NOT NULL,
 size_bytes INTEGER NOT NULL CHECK(size_bytes BETWEEN 1 AND 104857600),
 created_at TEXT NOT NULL,
 expires_at TEXT NOT NULL
);
CREATE INDEX idx_history_intent_expiry ON device_history_upload_intents(expires_at,storage_key);

CREATE TRIGGER history_usage_insert AFTER INSERT ON device_history_transfers WHEN NEW.state='active'
BEGIN
 INSERT INTO blob_usage_accounts(account_id,size_bytes) VALUES(NEW.account_id,NEW.size_bytes)
 ON CONFLICT(account_id) DO UPDATE SET size_bytes=size_bytes+excluded.size_bytes;
 UPDATE blob_usage_instance SET size_bytes=size_bytes+NEW.size_bytes WHERE id=1;
END;
CREATE TRIGGER history_usage_delete AFTER DELETE ON device_history_transfers WHEN OLD.state='active'
BEGIN
 UPDATE blob_usage_accounts SET size_bytes=size_bytes-OLD.size_bytes WHERE account_id=OLD.account_id;
 UPDATE blob_usage_instance SET size_bytes=size_bytes-OLD.size_bytes WHERE id=1;
END;
CREATE TRIGGER history_usage_terminal AFTER UPDATE OF state ON device_history_transfers WHEN OLD.state='active' AND NEW.state<>'active'
BEGIN
 UPDATE blob_usage_accounts SET size_bytes=size_bytes-OLD.size_bytes WHERE account_id=OLD.account_id;
 UPDATE blob_usage_instance SET size_bytes=size_bytes-OLD.size_bytes WHERE id=1;
END;
CREATE TRIGGER history_intent_usage_insert AFTER INSERT ON device_history_upload_intents
BEGIN
 INSERT INTO blob_usage_accounts(account_id,size_bytes) VALUES(NEW.account_id,NEW.size_bytes)
 ON CONFLICT(account_id) DO UPDATE SET size_bytes=size_bytes+excluded.size_bytes;
 UPDATE blob_usage_instance SET size_bytes=size_bytes+NEW.size_bytes WHERE id=1;
END;
CREATE TRIGGER history_intent_usage_delete AFTER DELETE ON device_history_upload_intents
BEGIN
 UPDATE blob_usage_accounts SET size_bytes=size_bytes-OLD.size_bytes WHERE account_id=OLD.account_id;
 UPDATE blob_usage_instance SET size_bytes=size_bytes-OLD.size_bytes WHERE id=1;
END;
