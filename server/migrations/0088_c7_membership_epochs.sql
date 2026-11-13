-- C7 review M3 and H2 (docs/designs/C7-channel-history.md, "Targeted
-- history_sync delivery"): the epochs a membership commit produced, so the
-- server accepts a history_sync tag only for an epoch that added or removed
-- a device. The commit route writes a row with every commit bundle that
-- names an Added or Removed device; the server learns nothing new (it
-- stores those lists with the commit). Existing groups are backfilled from
-- the join epochs it already holds; a removal-only epoch from before this
-- migration is not known and its late history_sync is refused (C7 is off by
-- default and has no release).
CREATE TABLE c7_membership_epochs (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  epoch INTEGER NOT NULL CHECK (epoch >= 0),
  PRIMARY KEY (conversation_id, epoch)
) WITHOUT ROWID;

INSERT OR IGNORE INTO c7_membership_epochs(conversation_id, epoch)
  SELECT DISTINCT conversation_id, joined_epoch FROM conversation_mls_devices;
