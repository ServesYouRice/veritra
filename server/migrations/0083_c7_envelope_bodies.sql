-- C7 step 3 (docs/designs/C7-channel-history.md, "Server: wire, storage,
-- routes"): the sealed body of each envelope in a community conversation,
-- stored opaquely beside its MLS reference and written in the send
-- transaction. A body lives exactly as long as its envelope: the cascade
-- removes it when the sweeper (or a conversation delete) removes the
-- envelope. Sync serves it from here; it is never copied into sync_events.
-- history_hidden is set by the history-hide route (author or moderator).
CREATE TABLE envelope_bodies (
  message_id TEXT PRIMARY KEY REFERENCES message_envelopes(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  channel_id TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  history_hidden INTEGER NOT NULL DEFAULT 0 CHECK (history_hidden IN (0, 1)),
  body BLOB NOT NULL
);
CREATE INDEX envelope_bodies_history
  ON envelope_bodies(conversation_id, channel_id, created_at);
