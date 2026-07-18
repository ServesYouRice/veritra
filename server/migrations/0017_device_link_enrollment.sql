ALTER TABLE device_links ADD COLUMN claimed_device_id TEXT;
ALTER TABLE device_links ADD COLUMN claim_challenge BLOB;

CREATE UNIQUE INDEX IF NOT EXISTS idx_device_links_claimed_device_id
ON device_links(claimed_device_id)
WHERE claimed_device_id IS NOT NULL;
