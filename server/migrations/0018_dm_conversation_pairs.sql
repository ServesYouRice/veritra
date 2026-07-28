CREATE TABLE dm_conversation_pairs (
  account_id_low TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  account_id_high TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL UNIQUE REFERENCES conversations(id) ON DELETE CASCADE,
  PRIMARY KEY(account_id_low, account_id_high),
  CHECK(account_id_low < account_id_high)
);

INSERT INTO dm_conversation_pairs(account_id_low, account_id_high, conversation_id)
SELECT MIN(m.account_id), MAX(m.account_id), c.id
FROM conversations c
JOIN memberships m ON m.conversation_id = c.id
WHERE c.kind = 'dm'
GROUP BY c.id
HAVING COUNT(*) = 2 AND COUNT(DISTINCT m.account_id) = 2;

CREATE TABLE dm_pair_migration_guard (
  invalid INTEGER NOT NULL CHECK(invalid = 0)
);

INSERT INTO dm_pair_migration_guard(invalid)
SELECT 1
WHERE EXISTS (
  SELECT 1
  FROM conversations c
  WHERE c.kind = 'dm'
    AND NOT EXISTS (
      SELECT 1 FROM dm_conversation_pairs p WHERE p.conversation_id = c.id
    )
);

DROP TABLE dm_pair_migration_guard;
