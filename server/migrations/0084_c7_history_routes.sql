-- C7 step 3, history routes (docs/designs/C7-channel-history.md, "Server:
-- wire, storage, routes"). Each body records the sync event that carried
-- its envelope and the MLS epoch the envelope names, so the history fetch
-- serves exactly what the I51 join filter withheld from a device: bodies
-- before its joined_after_event_id, or after it in an epoch before its
-- joined_epoch. Bodies stored before this migration have neither and are
-- never served by the history fetch (there is no release; C7 is off).
ALTER TABLE envelope_bodies ADD COLUMN sync_event_id INTEGER;
ALTER TABLE envelope_bodies ADD COLUMN mls_epoch INTEGER;
CREATE INDEX envelope_bodies_fetch
  ON envelope_bodies(conversation_id, channel_id, sync_event_id);

-- A moderator's history-hide is audited like the other C5 actions: ids and
-- the action kind only. SQLite cannot widen a CHECK in place, so the table
-- is rebuilt; nothing references it.
CREATE TABLE moderation_events_c7 (
  id TEXT PRIMARY KEY,
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  actor_account_id TEXT NOT NULL,
  target_account_id TEXT,
  channel_id TEXT,
  action TEXT NOT NULL CHECK (action IN ('kick', 'ban', 'unban', 'timeout', 'timeout_cleared', 'slow_mode', 'invites_paused', 'invites_resumed', 'message_hidden')),
  created_at TEXT NOT NULL
);
INSERT INTO moderation_events_c7(id, community_id, actor_account_id, target_account_id, channel_id, action, created_at)
  SELECT id, community_id, actor_account_id, target_account_id, channel_id, action, created_at FROM moderation_events;
DROP TABLE moderation_events;
ALTER TABLE moderation_events_c7 RENAME TO moderation_events;
CREATE INDEX moderation_events_community ON moderation_events(community_id, created_at DESC, id);
