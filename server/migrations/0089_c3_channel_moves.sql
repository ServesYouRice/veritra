-- C3 channel conversion, C7 decision 11 (docs/designs/C7-channel-history.md;
-- docs/crypto.md, "C3 channel conversion"): one row per move of a routed
-- channel to another conversation. cutoff_event_id is the newest sync event
-- when the move committed: the old conversation's bodies up to it are what
-- members of the destination may read through the move routes. The server
-- learns nothing new: it re-routes the channel itself. A move row outlives
-- neither conversation.
CREATE TABLE c3_channel_moves (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  from_conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  to_conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  from_access TEXT NOT NULL CHECK (from_access IN ('open', 'announcement', 'private')),
  to_access TEXT NOT NULL CHECK (to_access IN ('open', 'announcement', 'private')),
  cutoff_event_id INTEGER NOT NULL CHECK (cutoff_event_id >= 0),
  moved_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  CHECK (from_conversation_id <> to_conversation_id),
  CHECK ((from_access = 'private') <> (to_access = 'private'))
);
CREATE INDEX c3_channel_moves_from ON c3_channel_moves(channel_id, from_conversation_id);
