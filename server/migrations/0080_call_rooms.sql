-- B6 group calls and voice rooms (docs/designs/B6-group-calls.md, S3).
-- A room is one call of a conversation: one live call per conversation. The
-- server stores who joined, the call group's epoch and the opaque MLS
-- commits and Welcomes (ciphertext only). It never sees media or keys.
CREATE TABLE call_rooms (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sfu_room TEXT NOT NULL UNIQUE,
    group_id BLOB NOT NULL,
    epoch INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    ended_at TEXT
);
CREATE UNIQUE INDEX call_rooms_one_live ON call_rooms(conversation_id) WHERE ended_at IS NULL;
CREATE INDEX call_rooms_ended ON call_rooms(ended_at) WHERE ended_at IS NOT NULL;

CREATE TABLE call_room_participants (
    room_id TEXT NOT NULL REFERENCES call_rooms(id) ON DELETE CASCADE,
    identity TEXT NOT NULL,
    device_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    joined_at TEXT NOT NULL,
    left_at TEXT,
    -- The join offer (B6 S5): a call-only KeyPackage and the credential
    -- key's signature over it. Opaque to the server; members check it.
    nonce TEXT NOT NULL,
    nonce_expires_at TEXT NOT NULL,
    offer_key_package BLOB,
    offer_signature BLOB,
    offer_expires_at INTEGER,
    in_group INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (room_id, identity)
);
CREATE UNIQUE INDEX call_room_participants_live ON call_room_participants(room_id, device_id) WHERE left_at IS NULL;

CREATE TABLE call_room_commits (
    room_id TEXT NOT NULL REFERENCES call_rooms(id) ON DELETE CASCADE,
    epoch INTEGER NOT NULL,
    committer_device_id TEXT NOT NULL,
    commit_bytes BLOB NOT NULL,
    welcome_bytes BLOB,
    created_at TEXT NOT NULL,
    PRIMARY KEY (room_id, epoch)
);
