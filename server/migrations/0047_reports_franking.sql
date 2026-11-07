-- C6: message franking and sealed reports (docs/designs/C6-reports-franking.md).
--
-- frank_commit is the sender's 32-byte commitment (HMAC-SHA256, computed by
-- the apps). The server can neither compute nor check it. It lives in its own
-- column, never inside crypto_metadata_json, and is written once at insert
-- (condition G3): the trigger below refuses any later change, so no code path
-- can alter it, including future ones. NULL means an unfranked message.
ALTER TABLE message_envelopes ADD COLUMN frank_commit BLOB CHECK (frank_commit IS NULL OR length(frank_commit) = 32);

CREATE TRIGGER IF NOT EXISTS message_envelopes_frank_commit_write_once
BEFORE UPDATE OF frank_commit ON message_envelopes
WHEN NEW.frank_commit IS NOT OLD.frank_commit
BEGIN
  SELECT RAISE(ABORT, 'frank_commit is write-once');
END;

-- Public report keys, one per inbox. 'instance_owner' (inbox_id 'instance') is
-- the instance owners' report key, published by an owner. 'community' is a
-- community's moderator inbox key (inbox_id = community id); it needs C4's
-- role state to be distributed, so no route publishes it yet. key_rev rises
-- with every changed key and is bound into each report's aad.
CREATE TABLE IF NOT EXISTS report_inbox_keys (
  inbox_kind TEXT NOT NULL CHECK (inbox_kind IN ('instance_owner', 'community')),
  inbox_id TEXT NOT NULL CHECK (length(inbox_id) BETWEEN 1 AND 128),
  public_key BLOB NOT NULL CHECK (length(public_key) = 32),
  key_rev INTEGER NOT NULL CHECK (key_rev >= 1),
  set_by_account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (inbox_kind, inbox_id)
);

-- A filed report. sealed is opaque ciphertext (HPKE, "VRP1"): the server never
-- reads it. The sender, commitment and envelope time are copied from the
-- envelope row when the report is filed, by the server, never from the
-- reporter: they are the server's recorded evidence (condition G1), and they
-- survive the envelope being pruned (open item 2). envelope_id has no foreign
-- key for the same reason. One report per reporter and message.
CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  inbox_kind TEXT NOT NULL CHECK (inbox_kind IN ('instance_owner', 'community')),
  inbox_id TEXT NOT NULL CHECK (length(inbox_id) BETWEEN 1 AND 128),
  key_rev INTEGER NOT NULL CHECK (key_rev >= 1),
  recipient_public_key BLOB NOT NULL CHECK (length(recipient_public_key) = 32),
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  envelope_id TEXT NOT NULL CHECK (length(envelope_id) BETWEEN 1 AND 128),
  reporter_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sender_account_id TEXT NOT NULL,
  sender_device_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  frank_commit BLOB NOT NULL CHECK (length(frank_commit) = 32),
  envelope_created_at TEXT NOT NULL,
  sealed BLOB NOT NULL CHECK (length(sealed) BETWEEN 53 AND 262196),
  created_at TEXT NOT NULL,
  UNIQUE (reporter_account_id, envelope_id)
);

CREATE INDEX IF NOT EXISTS idx_reports_inbox ON reports(inbox_kind, inbox_id, created_at, id);
CREATE INDEX IF NOT EXISTS idx_reports_reporter_created ON reports(reporter_account_id, created_at);
