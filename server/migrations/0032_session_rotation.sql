-- Card T37C: a session keeps the token it rotated out for a short grace so
-- requests already in flight still complete. Additive; older binaries ignore
-- both columns and keep accepting the current token.
ALTER TABLE sessions ADD COLUMN previous_token_hash TEXT;
ALTER TABLE sessions ADD COLUMN previous_expires_at TEXT;

CREATE INDEX IF NOT EXISTS idx_sessions_previous_token
    ON sessions(previous_token_hash)
    WHERE previous_token_hash IS NOT NULL;
