-- C3: encrypted community info (docs/designs/C3-private-channels-and-info.md).
-- Community, category and channel names, topics and icons reuse W11's
-- encrypted_profiles table with three more subject kinds. The server never
-- sees a category's name or its place in the tree: it only learns that a
-- category ID belongs to a community, so it can tell who may read and write
-- the category's record. Category IDs are chosen by the app; the first write
-- binds one to its community. Additive: no existing row or table changes.

CREATE TABLE community_categories (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  created_by_account_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX community_categories_community ON community_categories(community_id);

-- A record outlives nothing it describes: when a community, category or
-- channel row goes, its ciphertext goes with it.
CREATE TRIGGER community_info_drop_community AFTER DELETE ON communities BEGIN
  DELETE FROM encrypted_profiles WHERE subject_kind = 'community' AND subject_id = OLD.id;
END;
CREATE TRIGGER community_info_drop_category AFTER DELETE ON community_categories BEGIN
  DELETE FROM encrypted_profiles WHERE subject_kind = 'category' AND subject_id = OLD.id;
END;
CREATE TRIGGER community_info_drop_channel AFTER DELETE ON channels BEGIN
  DELETE FROM encrypted_profiles WHERE subject_kind = 'channel' AND subject_id = OLD.id;
END;
