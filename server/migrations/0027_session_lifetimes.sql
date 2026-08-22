ALTER TABLE sessions ADD COLUMN last_used_at TEXT;
ALTER TABLE sessions ADD COLUMN absolute_expires_at TEXT;

UPDATE sessions
SET last_used_at = COALESCE(last_used_at, created_at),
    absolute_expires_at = COALESCE(
        absolute_expires_at,
        strftime('%Y-%m-%dT%H:%M:%fZ', created_at, '+30 days')
    );

CREATE INDEX IF NOT EXISTS idx_sessions_absolute_expires
    ON sessions(absolute_expires_at);
