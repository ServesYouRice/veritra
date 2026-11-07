-- W11: encrypted profiles (docs/designs/W11-profiles.md). One opaque record
-- per account and per group conversation. The server stores ciphertext, a
-- version counter, a key id (a hash of the key, never the key), the size and
-- the writer. It cannot read a name or a photo. Additive: no existing row or
-- table changes.

CREATE TABLE encrypted_profiles (
  subject_kind TEXT NOT NULL CHECK (subject_kind IN ('account', 'conversation')),
  subject_id TEXT NOT NULL,
  version INTEGER NOT NULL CHECK (version >= 1),
  key_id TEXT NOT NULL CHECK (length(key_id) = 32),
  ciphertext BLOB NOT NULL,
  size_bytes INTEGER NOT NULL CHECK (size_bytes > 0),
  updated_by_account_id TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (subject_kind, subject_id)
) WITHOUT ROWID;
