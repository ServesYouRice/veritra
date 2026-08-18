ALTER TABLE call_sessions ADD COLUMN invited_account_id TEXT NOT NULL DEFAULT '';
ALTER TABLE call_sessions ADD COLUMN version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE call_sessions ADD COLUMN create_action_id TEXT NOT NULL DEFAULT '';
ALTER TABLE call_sessions ADD COLUMN create_action_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE call_sessions ADD COLUMN last_action_id TEXT NOT NULL DEFAULT '';
ALTER TABLE call_sessions ADD COLUMN last_action_hash TEXT NOT NULL DEFAULT '';

-- Preserve only legacy calls whose participant snapshot is provable from an
-- active, exactly two-account DM. Unsupported legacy group/channel calls stay
-- un-authorized and are rejected by the service until they expire.
UPDATE call_sessions
SET invited_account_id = (
  SELECT m.account_id
  FROM memberships m
  JOIN accounts a ON a.id = m.account_id
  WHERE m.conversation_id = call_sessions.conversation_id
    AND m.account_id <> call_sessions.created_by
    AND a.status = 'active'
    AND a.deleted_at IS NULL
  ORDER BY m.account_id
  LIMIT 1
)
WHERE invited_account_id = ''
  AND EXISTS (
    SELECT 1
    FROM conversations c
    WHERE c.id = call_sessions.conversation_id
      AND c.kind = 'dm'
  )
  AND EXISTS (
    SELECT 1
    FROM memberships m
    JOIN accounts a ON a.id = m.account_id
    WHERE m.conversation_id = call_sessions.conversation_id
      AND m.account_id = call_sessions.created_by
      AND a.status = 'active'
      AND a.deleted_at IS NULL
  )
  AND (
    SELECT COUNT(*)
    FROM memberships m
    JOIN accounts a ON a.id = m.account_id
    WHERE m.conversation_id = call_sessions.conversation_id
      AND a.status = 'active'
      AND a.deleted_at IS NULL
  ) = 2;

CREATE INDEX IF NOT EXISTS idx_call_sessions_participants
  ON call_sessions(created_by, invited_account_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_call_sessions_create_action
  ON call_sessions(conversation_id, created_by, create_action_id)
  WHERE create_action_id <> '';
