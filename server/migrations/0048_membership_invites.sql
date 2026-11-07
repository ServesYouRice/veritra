-- C1: membership invitations and join requests for groups and communities.
--
-- An invitation link carries a secret after the '#', which a client never
-- sends anywhere. The creating app derives a locator from that secret and
-- sends the locator only; the server keeps SHA-256(locator) in locator_hash
-- and never sees the secret. The locator finds the invitation when a signed-in
-- account previews it or asks to join. A request grants nothing: membership
-- begins only when an owner or admin of the target approves it (one
-- transaction with the membership rows and their sync events).
--
-- Exactly one of community_id and conversation_id names the target (a group;
-- community channels belong to their community and take no invitation).
-- uses counts approvals, so max_uses bounds how many accounts one link can
-- bring in. Revoking an invitation cancels its pending requests.
--
-- Binding (D90). The creating device also binds the invitation to its target,
-- account and device keys: binding_tag is HMAC-SHA256, keyed from the link
-- secret, over the origin, target, creating account, creating device and that
-- device's signing key. The server cannot compute or check it (it never has
-- the secret); it stores the tag and the creating device's id and signing key
-- (taken from devices, never from the request) and returns them with the
-- preview, so the joiner can recompute the tag from the link and refuse a
-- swapped target. The invitation stops working when that device is revoked.

CREATE TABLE membership_invites (
  id TEXT PRIMARY KEY,
  community_id TEXT REFERENCES communities(id) ON DELETE CASCADE,
  conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
  created_by TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_by_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  creator_signing_key BLOB NOT NULL CHECK (length(creator_signing_key) = 32),
  binding_tag TEXT NOT NULL CHECK (length(binding_tag) = 64),
  locator_hash TEXT NOT NULL UNIQUE CHECK (length(locator_hash) = 64),
  max_uses INTEGER NOT NULL CHECK (max_uses BETWEEN 1 AND 1000),
  uses INTEGER NOT NULL DEFAULT 0 CHECK (uses >= 0),
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT,
  CHECK ((community_id IS NULL) <> (conversation_id IS NULL))
);

CREATE INDEX idx_membership_invites_community ON membership_invites(community_id, created_at) WHERE community_id IS NOT NULL;
CREATE INDEX idx_membership_invites_conversation ON membership_invites(conversation_id, created_at) WHERE conversation_id IS NOT NULL;
CREATE INDEX idx_membership_invites_creator ON membership_invites(created_by);
CREATE INDEX idx_membership_invites_retention ON membership_invites(expires_at);

CREATE TABLE membership_join_requests (
  id TEXT PRIMARY KEY,
  invite_id TEXT NOT NULL REFERENCES membership_invites(id) ON DELETE CASCADE,
  community_id TEXT REFERENCES communities(id) ON DELETE CASCADE,
  conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  created_at TEXT NOT NULL,
  decided_by TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  decided_at TEXT,
  CHECK ((community_id IS NULL) <> (conversation_id IS NULL)),
  CHECK ((status = 'pending') = (decided_at IS NULL))
);

-- One pending request per account and target.
CREATE UNIQUE INDEX uniq_join_request_pending_community ON membership_join_requests(account_id, community_id) WHERE status = 'pending' AND community_id IS NOT NULL;
CREATE UNIQUE INDEX uniq_join_request_pending_conversation ON membership_join_requests(account_id, conversation_id) WHERE status = 'pending' AND conversation_id IS NOT NULL;
CREATE INDEX idx_join_requests_community ON membership_join_requests(community_id, status, created_at) WHERE community_id IS NOT NULL;
CREATE INDEX idx_join_requests_conversation ON membership_join_requests(conversation_id, status, created_at) WHERE conversation_id IS NOT NULL;
CREATE INDEX idx_join_requests_account ON membership_join_requests(account_id, created_at);
CREATE INDEX idx_join_requests_invite ON membership_join_requests(invite_id);
CREATE INDEX idx_join_requests_retention ON membership_join_requests(decided_at) WHERE decided_at IS NOT NULL;
