-- L2-3 sealed sender (D122; docs/crypto.md, "Sealed sender with VOPRF
-- tokens"): the instance's POPRF key, each conversation's token generation,
-- per-account issuance counts and spent token nonces. Nothing here names who
-- spent a token: issuance is per account, spending is anonymous.
--
-- One key per instance, made on first use. The private scalar is server key
-- material like the VAPID key; whoever holds it can post junk into
-- conversations whose ids they know and reads nothing.
CREATE TABLE IF NOT EXISTS sealed_sender_keys (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  key_id TEXT NOT NULL CHECK (length(key_id) = 32),
  private_key BLOB NOT NULL CHECK (length(private_key) = 32),
  public_key BLOB NOT NULL CHECK (length(public_key) = 32),
  created_at TEXT NOT NULL
);

-- The generation tokens are bound to. Raised by the triggers below whenever
-- a member leaves (or is removed, banned or deleted) and whenever a member's
-- device is revoked, so leftover tokens of a removed member or a revoked
-- device stop working at once. No row means generation 0. No foreign key:
-- the membership trigger can fire while a conversation's delete cascades,
-- and a counter left behind for a deleted id names nothing.
CREATE TABLE IF NOT EXISTS sealed_conversation_state (
  conversation_id TEXT PRIMARY KEY,
  generation INTEGER NOT NULL CHECK (generation >= 0)
) WITHOUT ROWID;

CREATE TRIGGER IF NOT EXISTS sealed_generation_on_membership_delete
AFTER DELETE ON memberships
WHEN OLD.conversation_id IS NOT NULL
BEGIN
  INSERT INTO sealed_conversation_state(conversation_id, generation)
  SELECT OLD.conversation_id, 1
  WHERE EXISTS (SELECT 1 FROM conversations WHERE id = OLD.conversation_id)
  ON CONFLICT(conversation_id) DO UPDATE SET generation = generation + 1;
END;

CREATE TRIGGER IF NOT EXISTS sealed_generation_on_device_revoke
AFTER UPDATE OF revoked_at ON devices
WHEN OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
BEGIN
  INSERT INTO sealed_conversation_state(conversation_id, generation)
  SELECT m.conversation_id, 1 FROM memberships m
  WHERE m.account_id = NEW.account_id AND m.conversation_id IS NOT NULL
  ON CONFLICT(conversation_id) DO UPDATE SET generation = generation + 1;
END;

CREATE TRIGGER IF NOT EXISTS sealed_state_on_conversation_delete
AFTER DELETE ON conversations
BEGIN
  DELETE FROM sealed_conversation_state WHERE conversation_id = OLD.id;
END;

-- Tokens issued per account, conversation and UTC day (the epoch), for the
-- daily cap. Deleted once the epoch can no longer be redeemed.
CREATE TABLE IF NOT EXISTS sealed_token_issuance (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  epoch INTEGER NOT NULL CHECK (epoch >= 0),
  issued INTEGER NOT NULL CHECK (issued >= 0),
  PRIMARY KEY (account_id, conversation_id, epoch)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_sealed_token_issuance_epoch ON sealed_token_issuance(epoch);

-- Spent nonces: a second use is refused. message_id names the envelope the
-- token paid for, for the idempotent retry; it has no foreign key because a
-- spent nonce stays spent after its envelope expires. Deleted once the epoch
-- can no longer be redeemed.
CREATE TABLE IF NOT EXISTS sealed_spent_tokens (
  key_id TEXT NOT NULL,
  epoch INTEGER NOT NULL CHECK (epoch >= 0),
  nonce BLOB NOT NULL CHECK (length(nonce) = 32),
  message_id TEXT NOT NULL,
  PRIMARY KEY (key_id, epoch, nonce)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_sealed_spent_tokens_epoch ON sealed_spent_tokens(epoch);
