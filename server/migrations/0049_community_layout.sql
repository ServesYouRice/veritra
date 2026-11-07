-- C0 / C1 prerequisite 2: shared-group routing for communities (additive).
--
-- A community in the 'active' layout has one shared conversation for its open
-- and announcement channels and one conversation per private channel. A
-- community in the 'legacy' layout keeps one conversation per channel exactly
-- as before. This migration only adds sidecar tables and gives every existing
-- community a 'legacy' row: no conversation, message, membership or MLS row is
-- changed, and no legacy community is converted (docs/designs/C0-preserving-migration.md).
-- Conversations keep their physical kind; the shared one is projected as
-- 'community_shared' by community_layout_store.go.

CREATE TABLE community_layouts (
  community_id TEXT PRIMARY KEY REFERENCES communities(id) ON DELETE CASCADE,
  version INTEGER NOT NULL CHECK (version = 1),
  state TEXT NOT NULL CHECK (state IN ('legacy', 'active')),
  generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
  shared_conversation_id TEXT REFERENCES conversations(id),
  CHECK (state <> 'active' OR (shared_conversation_id IS NOT NULL AND generation >= 1)),
  CHECK (state <> 'legacy' OR (shared_conversation_id IS NULL AND generation = 0))
);

CREATE TABLE community_conversation_layouts (
  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  purpose TEXT NOT NULL CHECK (purpose IN ('shared', 'private')),
  generation INTEGER NOT NULL CHECK (generation >= 1)
);
CREATE UNIQUE INDEX community_one_shared_conversation
  ON community_conversation_layouts(community_id) WHERE purpose = 'shared';

CREATE TABLE community_channel_routes (
  channel_id TEXT PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
  community_id TEXT NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  access_mode TEXT NOT NULL CHECK (access_mode IN ('open', 'announcement', 'private')),
  generation INTEGER NOT NULL CHECK (generation >= 1)
);
CREATE INDEX community_routes_conversation
  ON community_channel_routes(conversation_id, channel_id);

INSERT INTO community_layouts(community_id, version, state, generation)
  SELECT id, 1, 'legacy', 0 FROM communities;
