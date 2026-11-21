-- C5: a timeout outlives the membership row it was set on, so leaving the
-- community (or being kicked) and joining again does not end it early. The
-- membership column `timeout_until` stays what every check reads; this table
-- only remembers the end of the last timeout per community and account, and
-- a trigger copies it onto a new community membership row. Ids and times
-- only, as for the rest of C5. Deleting an account deletes its rows
-- (account_store.go). A later rebuild of `memberships` drops the trigger
-- with the old table and must create it again
-- (TestTimeoutSurvivesLeaveKickAndRejoin fails if it is missing).
CREATE TABLE member_timeouts (
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  timeout_until TEXT NOT NULL,
  PRIMARY KEY (community_id, account_id)
);

-- Timeouts set before this migration, on current members.
INSERT INTO member_timeouts(community_id, account_id, timeout_until)
SELECT community_id, account_id, MAX(timeout_until)
FROM memberships
WHERE community_id IS NOT NULL AND timeout_until IS NOT NULL
GROUP BY community_id, account_id;

CREATE TRIGGER memberships_keep_timeout
AFTER INSERT ON memberships
WHEN NEW.community_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM member_timeouts t
              WHERE t.community_id = NEW.community_id AND t.account_id = NEW.account_id)
BEGIN
  UPDATE memberships
  SET timeout_until = (SELECT t.timeout_until FROM member_timeouts t
                       WHERE t.community_id = NEW.community_id AND t.account_id = NEW.account_id)
  WHERE rowid = NEW.rowid;
END;
