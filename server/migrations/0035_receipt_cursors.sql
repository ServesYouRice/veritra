-- W5: ticks. Additive only.
--
-- delivery_receipts is one cursor per account and conversation, like
-- read_receipts: the newest message whose event a device of the account was
-- served. It holds no content, only a message id and a time. It is kept only
-- for DMs and small groups (see storage.ReceiptMaxMembers).
--
-- read_receipts.private marks a cursor kept only for the account's own unread
-- count (the account switched read receipts off). Private cursors are never
-- published and never listed to other members.
--
-- accounts.send_read_receipts is that switch, per account so every linked
-- device honours it. The server turns a read receipt private while it is 0.

ALTER TABLE read_receipts ADD COLUMN private INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN send_read_receipts INTEGER NOT NULL DEFAULT 1;

CREATE TABLE IF NOT EXISTS delivery_receipts (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  message_id TEXT NOT NULL REFERENCES message_envelopes(id) ON DELETE CASCADE,
  delivered_at TEXT NOT NULL,
  PRIMARY KEY(account_id, conversation_id)
);

-- The retention sweeper deletes envelopes in bulk; the cascade from an
-- envelope to the cursors that point at it must not scan a whole table.
CREATE INDEX IF NOT EXISTS idx_delivery_receipts_message
ON delivery_receipts(message_id);

CREATE INDEX IF NOT EXISTS idx_delivery_receipts_conversation
ON delivery_receipts(conversation_id);

CREATE INDEX IF NOT EXISTS idx_read_receipts_message
ON read_receipts(message_id);
