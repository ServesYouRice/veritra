ALTER TABLE device_links ADD COLUMN protocol_version TEXT NOT NULL DEFAULT 'veritra-device-link-v1';
ALTER TABLE device_links ADD COLUMN link_nonce BLOB;
ALTER TABLE device_links ADD COLUMN claimed_transcript_hash BLOB;
