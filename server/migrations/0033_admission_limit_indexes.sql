-- T49D: admission limits count per-account rows inside the single-writer
-- transaction that adds a row. These indexes keep each count proportional to
-- that account's (or community's) own rows instead of scanning the table.
-- Additive only; dropping them is safe.
CREATE INDEX IF NOT EXISTS idx_attachment_envelopes_owner
ON attachment_envelopes(owner_account_id);

CREATE INDEX IF NOT EXISTS idx_backup_blobs_account
ON backup_blobs(account_id);

CREATE INDEX IF NOT EXISTS idx_memberships_community
ON memberships(community_id, account_id) WHERE community_id IS NOT NULL;
