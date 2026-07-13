CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_channel_unique
ON conversations(channel_id)
WHERE channel_id IS NOT NULL;
