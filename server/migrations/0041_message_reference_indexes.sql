-- reply_to_id and thread_root_id reference message_envelopes(id) with ON DELETE
-- SET NULL. With foreign keys enforced, every envelope delete looks up its
-- children by these columns; without an index each lookup scans the table, so
-- a batch of expired messages cost the batch size times the whole history.
-- Plain indexes, so the foreign-key lookups can use them.
CREATE INDEX IF NOT EXISTS idx_message_envelopes_reply_to
  ON message_envelopes(reply_to_id);
CREATE INDEX IF NOT EXISTS idx_message_envelopes_thread_root
  ON message_envelopes(thread_root_id);
