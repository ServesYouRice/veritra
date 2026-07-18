CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
CREATE INDEX IF NOT EXISTS idx_invites_expires ON invites(expires_at, id) WHERE expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_invites_revoked ON invites(revoked_at, id) WHERE revoked_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_device_links_expires ON device_links(expires_at, id);
CREATE INDEX IF NOT EXISTS idx_push_disabled ON push_subscriptions(disabled_at, id) WHERE disabled_at IS NOT NULL;
