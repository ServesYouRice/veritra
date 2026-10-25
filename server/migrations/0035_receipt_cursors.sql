-- W5: ticks. Additive only.
--
-- read_receipts.message_id stays the account's own read cursor (it drives the
-- unread count). shared_message_id is the cursor other members may see: only
-- a read made while the account shares read receipts moves it, and only
-- forward. Switching receipts off therefore freezes it where it was. It is
-- cleared if the message it names is deleted.
--
-- delivery_receipts is one cursor per account and conversation: the newest
-- message whose event a device of the account was served. It holds ids only,
-- no content and no time, and is kept only for DMs and small groups (see
-- storage.ReceiptMaxMembers).
--
-- accounts.send_read_receipts is the switch, per account so every linked
-- device honours it. The server stops moving shared_message_id while it is 0.
-- A server binary from before this migration ignores the switch (the change
-- is forward-only).

ALTER TABLE read_receipts ADD COLUMN shared_message_id TEXT REFERENCES message_envelopes(id) ON DELETE SET NULL;
UPDATE read_receipts SET shared_message_id = message_id;
ALTER TABLE accounts ADD COLUMN send_read_receipts INTEGER NOT NULL DEFAULT 1;

CREATE TABLE IF NOT EXISTS delivery_receipts (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  message_id TEXT NOT NULL REFERENCES message_envelopes(id) ON DELETE CASCADE,
  PRIMARY KEY(account_id, conversation_id)
);

-- The retention sweeper deletes envelopes in bulk; the cascade or SET NULL
-- from an envelope to the cursors that point at it must not scan a table.
CREATE INDEX IF NOT EXISTS idx_delivery_receipts_message
ON delivery_receipts(message_id);

CREATE INDEX IF NOT EXISTS idx_delivery_receipts_conversation
ON delivery_receipts(conversation_id);

CREATE INDEX IF NOT EXISTS idx_read_receipts_message
ON read_receipts(message_id);

CREATE INDEX IF NOT EXISTS idx_read_receipts_shared_message
ON read_receipts(shared_message_id);
