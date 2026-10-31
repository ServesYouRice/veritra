-- Sync cursor expiry from prune watermarks.
--
-- A sync cursor has expired when retention pruned an event, after the
-- cursor, that the device could have been sent. Sync event ids are global
-- across accounts, so the old test (the cursor's own event is gone and the
-- account's oldest remaining event is more than one id past it) took other
-- accounts' events in that gap for missed ones and refused cursors that had
-- missed nothing.
--
-- These tables record, for each place a device reads events from, the
-- highest event id ever pruned from it:
--   * sync_prune_account_marks: an account's own events, per target device
--     ('' for events every device of the account receives);
--   * sync_prune_conversation_marks: a conversation's events, split into the
--     ones sync filters by the device's MLS join cursor (roster_filtered = 1:
--     mls.message.created, message.envelope.*, call.*, as in
--     syncEventVisibleTo) and the rest.
-- A cursor has expired when one of its account's marks, or a mark of a
-- conversation it is a member of, is past it (ListSyncEvents). The marks keep
-- one event id per conversation, and per account and device, and nothing
-- else: no sender, type or time. A key per sender would make blocked
-- senders exact but keep who wrote where, and in what order, beyond event
-- retention.
--
-- sync_prune_state.pruned_through is the highest id ever pruned, so a cursor
-- at or past it needs no other read. legacy_through is where this
-- migration found the table: events at or below it were pruned before marks
-- were kept, so a cursor below it also gets the old test, which is safe but
-- has the false positives above.
--
-- The triggers run inside every DELETE on sync_events, so every path that
-- prunes (and the tests that delete directly) keeps the marks. An older
-- server binary ignores the tables and keeps its old test; the triggers keep
-- running under it, so rolling back and forward again needs no restore.

CREATE TABLE sync_prune_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  legacy_through INTEGER NOT NULL CHECK (legacy_through >= 0),
  pruned_through INTEGER NOT NULL CHECK (pruned_through >= 0)
);

-- Everything below the oldest surviving event was pruned (ids are
-- AUTOINCREMENT and retention deletes from the oldest); with no event left,
-- everything up to the last id ever issued was.
INSERT INTO sync_prune_state(id, legacy_through, pruned_through)
SELECT 1, through, through FROM (SELECT COALESCE(
  (SELECT MIN(id) - 1 FROM sync_events),
  (SELECT seq FROM sqlite_sequence WHERE name = 'sync_events'),
  0) AS through);

CREATE TABLE sync_prune_account_marks (
  account_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  pruned_through INTEGER NOT NULL,
  PRIMARY KEY (account_id, device_id)
) WITHOUT ROWID;

CREATE TABLE sync_prune_conversation_marks (
  conversation_id TEXT NOT NULL,
  roster_filtered INTEGER NOT NULL CHECK (roster_filtered IN (0, 1)),
  pruned_through INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, roster_filtered)
) WITHOUT ROWID;

CREATE TRIGGER sync_prune_high_water AFTER DELETE ON sync_events
BEGIN
  UPDATE sync_prune_state SET pruned_through = MAX(pruned_through, OLD.id) WHERE id = 1;
END;

CREATE TRIGGER sync_prune_account_mark AFTER DELETE ON sync_events
WHEN OLD.account_id IS NOT NULL
BEGIN
  INSERT INTO sync_prune_account_marks(account_id, device_id, pruned_through)
  VALUES(OLD.account_id, COALESCE(OLD.device_id, ''), OLD.id)
  ON CONFLICT(account_id, device_id) DO UPDATE SET pruned_through = MAX(pruned_through, excluded.pruned_through);
END;

-- A message event whose message has expired, is gone, or was deleted (all
-- but the delete marker) is hidden from every cursor for good
-- (syncEventVisibleTo), so pruning it takes nothing from anyone and leaves
-- no mark. Otherwise every disappearing message would expire the cursor of
-- a device that was away. The retention sweep drains expired messages
-- before it prunes events. The time text is formatTime's fixed-width layout,
-- as sqlNowText builds it. A retry that later stores a message under the
-- same id writes a new event, so the device still receives it.
CREATE TRIGGER sync_prune_conversation_mark AFTER DELETE ON sync_events
WHEN OLD.account_id IS NULL AND OLD.conversation_id IS NOT NULL
  AND (OLD.event_type NOT LIKE 'message.envelope.%' OR EXISTS (
    SELECT 1 FROM message_envelopes live
    WHERE live.id = json_extract(OLD.payload_json, '$.message_id')
      AND (live.expires_at IS NULL OR live.expires_at > (strftime('%Y-%m-%dT%H:%M:%S', 'now') || substr(strftime('%f', 'now'), 3) || '000000Z'))
      AND (live.deleted_at IS NULL OR OLD.event_type = 'message.envelope.deleted')))
BEGIN
  INSERT INTO sync_prune_conversation_marks(conversation_id, roster_filtered, pruned_through)
  VALUES(OLD.conversation_id,
    CASE WHEN OLD.event_type = 'mls.message.created' OR OLD.event_type LIKE 'message.envelope.%'
           OR OLD.event_type LIKE 'call.%' THEN 1 ELSE 0 END,
    OLD.id)
  ON CONFLICT(conversation_id, roster_filtered) DO UPDATE SET pruned_through = MAX(pruned_through, excluded.pruned_through);
END;
