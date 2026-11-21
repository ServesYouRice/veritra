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
-- by trigger from the MLS messages a conversation without a roster receives,
-- so no code path can forget one. Pruning a message does not touch either
-- table. Rows go with their conversation or device.
--
-- Evidence comes only from a device that already has it, as in MLS, where
-- only a leaf holder can add someone: the devices that existed at the
-- group's first message, and the recipient of a Welcome whose sender had
-- evidence when it was sent. A device's own messages give it nothing. The
-- legacy route (POST /conversations/{id}/mls/messages) accepts any message
-- from any member device, so counting senders, or Welcomes from any device,
-- would let a device with no leaf (one recovered through K0) post a junk
-- commit, or have a sibling post a junk Welcome naming it, and hold evidence
-- for good. Veritra has no external commits (crypto/rust/src/mls.rs refuses
-- them), so no leaf comes from a device's own commit.
--
-- Upgrade: the tables are seeded from the messages still retained, by the
-- same rules. What retention pruned before this migration is not
-- recoverable: a device whose only evidence was pruned stays without it
-- (it is then not a coordinator or a required confirmer, which costs a
-- revocation only the wait for it), and the seed's mark is the oldest
-- RETAINED message, so it may admit a device the moved rule had already
-- admitted. Devices that a completed recovery still on record created are
-- taken out of that grant: they never had a leaf from before their
-- recovery, and only a retained Welcome from a device with evidence admits
-- them.
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
-- rule, taken once, at that time). A device created later needs a Welcome
-- from a device with evidence.
CREATE TRIGGER mls_legacy_marks_grant AFTER INSERT ON mls_legacy_marks
BEGIN
  INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
  SELECT NEW.conversation_id, d.id
  FROM memberships m JOIN devices d ON d.account_id = m.account_id
  WHERE m.conversation_id = NEW.conversation_id AND d.created_at <= NEW.oldest_message_at;
END;

-- The mark goes first, so the sender of a group's first message (which
-- existed before it) has evidence when its Welcome is judged.
CREATE TRIGGER mls_legacy_message_evidence AFTER INSERT ON conversation_mls_messages
WHEN NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = NEW.conversation_id)
BEGIN
  INSERT OR IGNORE INTO mls_legacy_marks(conversation_id, oldest_message_at)
  VALUES(NEW.conversation_id, NEW.created_at);
  INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
  SELECT NEW.conversation_id, NEW.recipient_device_id
  WHERE NEW.kind = 'welcome' AND NEW.recipient_device_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM mls_legacy_leaf_evidence e
                WHERE e.conversation_id = NEW.conversation_id AND e.device_id = NEW.sender_device_id);
END;

-- Seed from what is retained. The marks come first so that their trigger
-- grants the old third rule; then recovered devices leave that grant; then
-- the Welcome recipients whose sender has evidence, transitively.
INSERT OR IGNORE INTO mls_legacy_marks(conversation_id, oldest_message_at)
SELECT conversation_id, MIN(created_at)
FROM conversation_mls_messages x
WHERE NOT EXISTS (SELECT 1 FROM conversation_mls_groups g WHERE g.conversation_id = x.conversation_id)
GROUP BY conversation_id;

DELETE FROM mls_legacy_leaf_evidence
WHERE device_id IN (SELECT device_id FROM account_recovery_requests WHERE state = 'completed');

WITH RECURSIVE welcomed(conversation_id, device_id) AS (
  SELECT conversation_id, device_id FROM mls_legacy_leaf_evidence
  UNION
  SELECT x.conversation_id, x.recipient_device_id
  FROM conversation_mls_messages x
  JOIN welcomed w ON w.conversation_id = x.conversation_id AND w.device_id = x.sender_device_id
  WHERE x.kind = 'welcome' AND x.recipient_device_id IS NOT NULL
)
INSERT OR IGNORE INTO mls_legacy_leaf_evidence(conversation_id, device_id)
SELECT conversation_id, device_id FROM welcomed;
