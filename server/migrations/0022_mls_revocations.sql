ALTER TABLE conversation_mls_messages ADD COLUMN revocation_device_id TEXT REFERENCES devices(id);

CREATE TABLE mls_revocations (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  revoked_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  revoked_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  coordinator_device_id TEXT NOT NULL REFERENCES devices(id),
  state TEXT NOT NULL CHECK(state IN ('pending', 'commit_submitted', 'completed')),
  commit_message_id TEXT REFERENCES conversation_mls_messages(id),
  requested_at TEXT NOT NULL,
  completed_at TEXT,
  PRIMARY KEY(conversation_id, revoked_device_id)
);

CREATE TABLE mls_revocation_required_devices (
  conversation_id TEXT NOT NULL,
  revoked_device_id TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  confirmed_at TEXT,
  PRIMARY KEY(conversation_id, revoked_device_id, device_id),
  FOREIGN KEY(conversation_id, revoked_device_id)
    REFERENCES mls_revocations(conversation_id, revoked_device_id) ON DELETE CASCADE
);

CREATE INDEX idx_mls_revocations_state
ON mls_revocations(state, coordinator_device_id);
