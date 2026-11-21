-- K0-R known limit, closed (docs/crypto.md, "K0 R2 review, legacy-group
-- revocation coordinator"). A legacy group (pre-I51: MLS messages, no
-- roster) records no leaves, so the revocation coordinator and the required
-- confirmers were devices that "show evidence of a leaf": they sent an MLS
-- message there, were the recipient of a Welcome there, or were no newer
-- than the OLDEST RETAINED message. Retention prunes the oldest messages
-- (sync_events cascade), so that third rule moved forward until it admitted
-- a device recovered through K0, which never has a leaf.
--
-- The evidence is now durable. mls_legacy_leaf_evidence holds one row per
-- (conversation, device) with evidence; mls_legacy_marks holds the time of
-- the conversation's first message, which is never raised. Both are filled
-- from the first MLS message a conversation without a roster receives and
-- from every later sender and Welcome recipient, by trigger, so no code path
-- can forget one. Pruning a message does not touch either table. Rows go
-- with their conversation or device.
--
-- Upgrade: the tables are seeded from the messages still retained, by the
-- same three rules as before. What retention pruned before this migration is
-- not recoverable, so a device it has already lost evidence for stays
-- without it (it was never admitted by the pruned rule, only by the moved
-- one).
CREATE TABLE mls_legacy_marks (
  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
  oldest_message_at TEXT NOT NULL
);

CREATE TABLE mls_legacy_leaf_evidence (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  PRIMARY KEY (conversation_id, device_id)
) WITHOUT ROWID;

-- A device that existed when the group's first message was written may hold
-- a leaf from that message on (the old "no newer than the oldest message"
-- rule, taken once, at that time). A device created later needs a send or a
-- Welcome.
CREATE TRIGGER mls_legacy_marks_grant AFTER INSERT ON mls_legacy_marks
BEGIN
  INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
  SELECT NEW.conversation_id, d.id
  FROM memberships m JOIN devices d ON d.account_id = m.account_id
  WHERE m.conversation_id = NEW.conversation_id AND d.created_at <= NEW.oldest_message_at;
END;

CREATE TRIGGER mls_legacy_message_evidence AFTER INSERT ON conversation_mls_messages
WHEN NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = NEW.conversation_id)
BEGIN
  INSERT OR IGNORE INTO mls_legacy_marks(conversation_id, oldest_message_at)
  VALUES(NEW.conversation_id, NEW.created_at);
  INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
  VALUES(NEW.conversation_id, NEW.sender_device_id);
  INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
  SELECT NEW.conversation_id, NEW.recipient_device_id
  WHERE NEW.kind = 'welcome' AND NEW.recipient_device_id IS NOT NULL;
END;

-- Seed from what is retained. The marks come first so that their trigger
-- grants the old third rule; then the senders and Welcome recipients.
INSERT OR IGNORE INTO mls_legacy_marks(conversation_id, oldest_message_at)
SELECT conversation_id, MIN(created_at)
FROM conversation_mls_messages x
WHERE NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = x.conversation_id)
GROUP BY conversation_id;

INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
SELECT conversation_id, sender_device_id
FROM conversation_mls_messages x
WHERE NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = x.conversation_id);

INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
SELECT conversation_id, recipient_device_id
FROM conversation_mls_messages x
WHERE kind = 'welcome' AND recipient_device_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = x.conversation_id);
