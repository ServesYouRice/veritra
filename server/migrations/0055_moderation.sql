-- C5 moderation: per-community bans, timeouts, slow mode, paused invites and an
-- append-only audit log of ids and action kinds. No reasons and no message
-- text are stored (the server never sees them).
CREATE TABLE member_bans (
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  banned_by TEXT NOT NULL, -- no foreign key: deleting the banner must not lift the ban
  created_at TEXT NOT NULL,
  PRIMARY KEY (community_id, account_id)
);

CREATE TABLE moderation_events (
  id TEXT PRIMARY KEY,
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  actor_account_id TEXT NOT NULL,
  target_account_id TEXT,
  channel_id TEXT,
  action TEXT NOT NULL CHECK (action IN ('kick', 'ban', 'unban', 'timeout', 'timeout_cleared', 'slow_mode', 'invites_paused', 'invites_resumed')),
  created_at TEXT NOT NULL
);
CREATE INDEX moderation_events_community ON moderation_events(community_id, created_at DESC, id);

-- The end of a timeout on the community membership row; null means none.
ALTER TABLE memberships ADD COLUMN timeout_until TEXT;
-- Seconds a non-moderator must wait between posts in the channel; 0 is off.
ALTER TABLE channels ADD COLUMN slow_mode_seconds INTEGER NOT NULL DEFAULT 0
  CHECK (slow_mode_seconds >= 0 AND slow_mode_seconds <= 21600);
ALTER TABLE communities ADD COLUMN invites_paused_until TEXT;
