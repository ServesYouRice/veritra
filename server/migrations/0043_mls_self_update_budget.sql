-- Periodic MLS self-update: a commit that adds and removes no one and only
-- refreshes the committer's leaf keys. Each accepted one moves the group to
-- a new epoch, so a device may submit one per conversation at most once per
-- PRIVATE_MESSENGER_LIMIT_MLS_SELF_UPDATE_MINUTES. The time of its last
-- accepted one lives on its roster row; NULL means never. An older server
-- binary ignores the column, so rolling back past this migration is safe.
ALTER TABLE conversation_mls_devices ADD COLUMN last_self_update_at TEXT;
