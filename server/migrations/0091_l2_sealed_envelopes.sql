-- L2-3 sealed sender (D122): envelopes posted with a token instead of a
-- session. There is no sender column at all; the sender is only inside the
-- MLS ciphertext. The franking commitment is written once, as for
-- message_envelopes (C6). Sealed envelopes are not edited or deleted through
-- the server (it cannot tell who may); they expire like any other.
CREATE TABLE IF NOT EXISTS sealed_message_envelopes (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  idempotency_key TEXT NOT NULL,
  ciphertext BLOB NOT NULL CHECK (length(ciphertext) > 0),
  crypto_protocol TEXT NOT NULL,
  crypto_metadata_json TEXT NOT NULL,
  frank_commit BLOB CHECK (frank_commit IS NULL OR length(frank_commit) = 32),
  created_at TEXT NOT NULL,
  expires_at TEXT,
  UNIQUE (conversation_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_sealed_message_envelopes_expires
  ON sealed_message_envelopes(expires_at) WHERE expires_at IS NOT NULL;

CREATE TRIGGER IF NOT EXISTS sealed_message_envelopes_frank_commit_write_once
BEFORE UPDATE OF frank_commit ON sealed_message_envelopes
WHEN NEW.frank_commit IS NOT OLD.frank_commit
BEGIN
  SELECT RAISE(ABORT, 'frank_commit is write-once');
END;

-- Devices whose app reads message.sealed.created (it asked sync for them
-- with ?sealed=1 while the switch was on). Tokens are issued for a
-- conversation only while every live device of every member is listed, so
-- no member device that would never see a sealed post is left out of one
-- (an older app is not sent sealed events at all; see syncReadsSealed).
-- Holds no secret and names no conversation.
CREATE TABLE IF NOT EXISTS sealed_capable_devices (
  device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  noted_at TEXT NOT NULL
) WITHOUT ROWID;
