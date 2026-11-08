-- C4 (D80): a group and a community each have one owner, and ownership only
-- moves by a transfer to an admin. Earlier builds let an owner grant "owner"
-- to anyone it outranked or equalled, so a conversation or community may hold
-- several owners. Keep one deterministically, make the others admins, then
-- enforce one owner per conversation and per community. Apps judge roles from
-- the group's own encrypted state (never these rows), so this changes only
-- what the server itself enforces.
--
-- Community rows: keep the community's creator if it is an owner, else the
-- oldest owner membership, then the smallest account id.
UPDATE memberships
SET role = 'admin'
WHERE role = 'owner'
  AND community_id IS NOT NULL
  AND account_id <> (
    SELECT m2.account_id
    FROM memberships m2
    JOIN communities c ON c.id = m2.community_id
    WHERE m2.community_id = memberships.community_id
      AND m2.role = 'owner'
    ORDER BY CASE WHEN m2.account_id = c.created_by THEN 0 ELSE 1 END,
             julianday(m2.created_at), m2.account_id
    LIMIT 1
  );

-- Conversation rows: keep the community's owner if the conversation belongs to
-- a community and that owner is in it, else the conversation's creator, else
-- the oldest owner membership, then the smallest account id.
UPDATE memberships
SET role = 'admin'
WHERE role = 'owner'
  AND conversation_id IS NOT NULL
  AND account_id <> (
    SELECT m2.account_id
    FROM memberships m2
    JOIN conversations c ON c.id = m2.conversation_id
    WHERE m2.conversation_id = memberships.conversation_id
      AND m2.role = 'owner'
    ORDER BY CASE
               WHEN EXISTS (SELECT 1 FROM memberships cm
                            WHERE cm.community_id = c.community_id
                              AND cm.account_id = m2.account_id
                              AND cm.role = 'owner') THEN 0
               WHEN m2.account_id = c.created_by THEN 1
               ELSE 2
             END,
             julianday(m2.created_at), m2.account_id
    LIMIT 1
  );

CREATE UNIQUE INDEX IF NOT EXISTS memberships_one_owner_per_conversation
ON memberships(conversation_id)
WHERE role = 'owner' AND conversation_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS memberships_one_owner_per_community
ON memberships(community_id)
WHERE role = 'owner' AND community_id IS NOT NULL;
