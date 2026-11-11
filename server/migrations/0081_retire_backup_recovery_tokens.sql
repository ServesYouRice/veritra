-- K1-6 (D91): the VBK2 upload and the 15-minute recovery-token route are
-- retired. Fail closed: no stored capability may stay live. The columns and
-- the unique index stay (SQLite cannot drop an indexed column cheaply, and
-- old rows keep their other data); nothing writes or reads them any more.
UPDATE backup_blobs SET recovery_token_hash = NULL, recovery_expires_at = NULL,
  recovery_next_offset = 0, recovery_bytes_served = 0, recovery_lease_id = NULL,
  recovery_lease_expires_at = NULL
WHERE recovery_token_hash IS NOT NULL OR recovery_lease_id IS NOT NULL;
