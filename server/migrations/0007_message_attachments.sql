CREATE TABLE IF NOT EXISTS message_attachments (
  message_id TEXT NOT NULL REFERENCES message_envelopes(id) ON DELETE CASCADE,
  attachment_id TEXT NOT NULL UNIQUE REFERENCES attachment_envelopes(id) ON DELETE CASCADE,
  PRIMARY KEY(message_id, attachment_id)
);

CREATE INDEX IF NOT EXISTS idx_message_attachments_message ON message_attachments(message_id);
CREATE INDEX IF NOT EXISTS idx_attachment_envelopes_created ON attachment_envelopes(created_at, id);
