ALTER TABLE backup_blobs ADD COLUMN recovery_expires_at TEXT;
ALTER TABLE backup_blobs ADD COLUMN recovery_next_offset INTEGER NOT NULL DEFAULT 0;
ALTER TABLE backup_blobs ADD COLUMN recovery_lease_id TEXT;
ALTER TABLE backup_blobs ADD COLUMN recovery_lease_expires_at TEXT;
