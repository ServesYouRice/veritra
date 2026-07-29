CREATE TABLE IF NOT EXISTS conversation_mls_messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sender_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  recipient_device_id TEXT REFERENCES devices(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('welcome', 'commit')),
  payload BLOB NOT NULL CHECK(length(payload) BETWEEN 1 AND 4194304),
  idempotency_key TEXT NOT NULL,
  sync_event_id INTEGER UNIQUE REFERENCES sync_events(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  UNIQUE(sender_device_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_mls_messages_conversation_event
ON conversation_mls_messages(conversation_id, sync_event_id);

CREATE INDEX IF NOT EXISTS idx_mls_messages_recipient_event
ON conversation_mls_messages(recipient_device_id, sync_event_id);
