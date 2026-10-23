-- T49A: conversation members by conversation, in join order. The
-- conversation list names each DM peer from this, and membership checks by
-- conversation stop scanning every membership on the instance.
CREATE INDEX IF NOT EXISTS idx_memberships_conversation_created
ON memberships(conversation_id, created_at, account_id);
