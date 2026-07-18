CREATE TABLE account_blocks (
  blocker_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  blocked_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY(blocker_account_id, blocked_account_id),
  CHECK(blocker_account_id <> blocked_account_id)
);

CREATE INDEX account_blocks_blocked_idx
  ON account_blocks(blocked_account_id, blocker_account_id);

CREATE TABLE conversation_notification_preferences (
  account_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  muted INTEGER NOT NULL DEFAULT 0 CHECK(muted IN (0, 1)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(account_id, conversation_id),
  FOREIGN KEY(account_id, conversation_id)
    REFERENCES memberships(account_id, conversation_id) ON DELETE CASCADE
);
