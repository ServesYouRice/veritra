-- Card I51: MLS group membership after creation.
--
-- Recipient-targeted MLS messages (Welcomes) are visible only to their
-- device, not to every device of the account.
ALTER TABLE sync_events ADD COLUMN device_id TEXT;

-- The server-side epoch of each conversation's MLS group. A commit is
-- accepted only when it was built on this epoch, which orders commits
-- without the server reading them.
CREATE TABLE conversation_mls_groups (
  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
  epoch INTEGER NOT NULL CHECK (epoch >= 0),
  updated_at TEXT NOT NULL
);

-- Which devices are in each group, and from which sync event on (join
-- cursor). A device receives the group's encrypted events only after
-- joined_after_event_id and, once removed, up to removed_after_event_id.
CREATE TABLE conversation_mls_devices (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  joined_after_event_id INTEGER NOT NULL CHECK (joined_after_event_id >= 0),
  -- The first epoch the device can decrypt. Application messages from an
  -- earlier epoch, sent late, are withheld from it.
  joined_epoch INTEGER NOT NULL CHECK (joined_epoch >= 0),
  removed_after_event_id INTEGER,
  PRIMARY KEY (conversation_id, device_id)
);

CREATE INDEX idx_conversation_mls_devices_device
ON conversation_mls_devices(device_id, conversation_id);

-- Groups created before this migration have no recorded roster. They keep
-- working as before, unfiltered, but cannot change membership; guessing a
-- roster from old messages could hide events from a device that needs them.
