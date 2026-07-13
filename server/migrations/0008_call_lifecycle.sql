ALTER TABLE call_sessions ADD COLUMN expires_at TEXT;
CREATE INDEX IF NOT EXISTS idx_call_sessions_expiry ON call_sessions(expires_at, id) WHERE expires_at IS NOT NULL;
