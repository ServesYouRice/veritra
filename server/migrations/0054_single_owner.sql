-- C4 (D80): a group has one owner, and ownership only moves by a transfer to
-- an admin. Earlier builds let an owner grant "owner" to anyone it outranked
-- or equalled, so a conversation may hold several owners. Keep the earliest
-- (oldest membership, then smallest id) and make the others admins, then
-- enforce one owner per conversation. Apps judge roles from the group's own
-- encrypted state (never this table), so this changes only what the server
-- itself enforces.
UPDATE memberships
SET role = 'admin'
WHERE role = 'owner'
  AND conversation_id IS NOT NULL
  AND id <> (
    SELECT first.id
    FROM memberships first
    WHERE first.conversation_id = memberships.conversation_id
      AND first.role = 'owner'
    ORDER BY first.created_at, first.id
    LIMIT 1
  );

CREATE UNIQUE INDEX IF NOT EXISTS memberships_one_owner_per_conversation
ON memberships(conversation_id)
WHERE role = 'owner' AND conversation_id IS NOT NULL;
