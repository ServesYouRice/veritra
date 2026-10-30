-- K2 durable enrollment is a separate protocol. Legacy v2 consuming GETs
-- cannot see these rows or mint a server-generated session for a v3 claim.
CREATE TABLE device_links_v3 (
  id TEXT PRIMARY KEY,
  code TEXT NOT NULL UNIQUE CHECK(length(code) = 64),
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  source_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  server_origin TEXT NOT NULL,
  create_ttl_seconds INTEGER NOT NULL CHECK(create_ttl_seconds BETWEEN 1 AND 1800),
  state TEXT NOT NULL CHECK(state IN ('pending','claimed','approved','consumed','revoked')),
  link_nonce BLOB NOT NULL CHECK(length(link_nonce) = 32),
  reservation_request_id TEXT CHECK(reservation_request_id IS NULL OR length(reservation_request_id) = 64),
  recipient_device_id TEXT UNIQUE,
  claim_challenge BLOB,
  device_name TEXT,
  key_package BLOB,
  signing_key BLOB CHECK(signing_key IS NULL OR length(signing_key) = 32),
  transfer_public_key BLOB CHECK(transfer_public_key IS NULL OR length(transfer_public_key) = 32),
  transcript_hash BLOB CHECK(transcript_hash IS NULL OR length(transcript_hash) = 32),
  claim_tag BLOB CHECK(claim_tag IS NULL OR length(claim_tag) = 32),
  approval_tag BLOB CHECK(approval_tag IS NULL OR length(approval_tag) = 32),
  claim_token_hash TEXT UNIQUE CHECK(claim_token_hash IS NULL OR length(claim_token_hash) = 64),
  device_secret_hash TEXT CHECK(device_secret_hash IS NULL OR length(device_secret_hash) = 64),
  initial_session_token_hash TEXT UNIQUE CHECK(initial_session_token_hash IS NULL OR length(initial_session_token_hash) = 64),
  claim_request_hash TEXT CHECK(claim_request_hash IS NULL OR length(claim_request_hash) = 64),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  claimed_at TEXT,
  approved_at TEXT,
  transfer_expires_at TEXT,
  completed_at TEXT,
  revoked_at TEXT
);
CREATE INDEX idx_device_links_v3_account_state ON device_links_v3(account_id, state, expires_at);
CREATE INDEX idx_device_links_v3_deadline ON device_links_v3(COALESCE(transfer_expires_at,expires_at), id);
