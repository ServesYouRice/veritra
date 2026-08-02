ALTER TABLE backup_blobs ADD COLUMN recovery_token_hash BLOB;
CREATE UNIQUE INDEX idx_backup_recovery_token_hash
ON backup_blobs(recovery_token_hash) WHERE recovery_token_hash IS NOT NULL;
