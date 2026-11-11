-- C3 step 4 (docs/designs/C3-private-channels-and-info.md, "Migration from
-- today"): community and channel names, topics and icons live only in the
-- encrypted info records (migration 0063). The server refuses plaintext names
-- at creation (400 plaintext_name_refused) and keeps none. There is no
-- release, so demo communities are recreated (C0's rule): existing names are
-- dropped, not migrated. conversations.title stays for groups; a community
-- channel's conversation keeps none.
DROP INDEX IF EXISTS idx_communities_name_nocase;
DROP INDEX IF EXISTS idx_channels_name_nocase;
ALTER TABLE communities DROP COLUMN name;
ALTER TABLE channels DROP COLUMN name;
UPDATE conversations SET title = NULL WHERE kind = 'community_channel';
