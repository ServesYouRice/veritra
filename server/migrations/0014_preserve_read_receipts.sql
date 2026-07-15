ALTER TABLE read_receipts RENAME TO read_receipts_old;

CREATE TABLE read_receipts (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  message_id TEXT REFERENCES message_envelopes(id) ON DELETE SET NULL,
  read_at TEXT NOT NULL,
  PRIMARY KEY(account_id, conversation_id)
);

INSERT INTO read_receipts(account_id, conversation_id, message_id, read_at)
SELECT account_id, conversation_id, message_id, read_at
FROM read_receipts_old;

DROP TABLE read_receipts_old;
