ALTER TABLE devices ADD COLUMN auth_secret_hash TEXT;
ALTER TABLE sessions ADD COLUMN recent_auth_at TEXT;
ALTER TABLE device_links ADD COLUMN claimed_auth_secret_hash TEXT;
