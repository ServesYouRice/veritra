-- C4 server succession (docs/designs/C4-custom-roles.md, "Server
-- succession"). The server's owner row follows a won election only when the
-- owner has been quiet in the group or community for 37 days by the server's
-- clock and a majority of its admins asked for the same candidate.
--
-- memberships.last_active_at: the UTC day (L2-2: day only) of the account's
-- last envelope or MLS commit in a conversation. Existing rows start at the
-- day of this migration, so no owner looks quiet because of it. NULL on a
-- later row means no activity since the membership's created_at.
ALTER TABLE memberships ADD COLUMN last_active_at TEXT;
UPDATE memberships SET last_active_at = strftime('%Y-%m-%d', 'now') || 'T00:00:00.000000000Z';

-- One ask per account and scope (a group, or a community), replaced by a
-- newer ask and cleared when ownership moves. Ids only.
CREATE TABLE IF NOT EXISTS owner_succession_requests (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
  community_id TEXT REFERENCES communities(id) ON DELETE CASCADE,
  candidate_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  CHECK ((conversation_id IS NULL) <> (community_id IS NULL)),
  UNIQUE(account_id, conversation_id),
  UNIQUE(account_id, community_id)
);
CREATE INDEX IF NOT EXISTS idx_owner_succession_conversation ON owner_succession_requests(conversation_id) WHERE conversation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_owner_succession_community ON owner_succession_requests(community_id) WHERE community_id IS NOT NULL;

-- C4 role-only commits (review finding, 2026-11-11): a bundle declared
-- role_change skips the self-update interval and the pending-removal hold,
-- and the flag is unverifiable here. Its own, shorter interval per device
-- and conversation keeps it from being a way to churn epochs.
ALTER TABLE conversation_mls_devices ADD COLUMN last_role_change_at TEXT;
