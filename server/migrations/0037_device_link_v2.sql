-- Link secrets never reach the server. Direction-separated opaque MACs only.
ALTER TABLE device_links ADD COLUMN claim_tag BLOB CHECK(claim_tag IS NULL OR length(claim_tag) = 32);
ALTER TABLE device_links ADD COLUMN approval_tag BLOB CHECK(approval_tag IS NULL OR length(approval_tag) = 32);
-- Existing sessions remain valid; unfinished v1 links must be created again.
UPDATE device_links SET state = 'revoked', revoked_at = CURRENT_TIMESTAMP
WHERE protocol_version <> 'veritra-device-link-v2' AND state IN ('pending', 'claimed', 'approved');
