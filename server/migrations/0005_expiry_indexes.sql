CREATE INDEX IF NOT EXISTS idx_messages_expires_at
ON message_envelopes(expires_at)
WHERE expires_at IS NOT NULL;
