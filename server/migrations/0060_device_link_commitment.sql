-- L1-3 (TASK-010, TASK-048, D100): commit-then-reveal for device links
-- (docs/designs/L1-3-link-commitment.md). Protocol veritra-device-link-v4.
--
-- The existing device commits to a fresh random when it creates the link
-- (source_commitment), the new device sends its own fresh random with the
-- claim (recipient_random), and the existing device reveals its random only
-- after it accepted that claim (source_random, revealed_at). All three are
-- opaque 32-byte values, written once; the SAS needs all of them, so a relay
-- that knows the link secret still gets one 10^-8 guess per run.
ALTER TABLE device_links_v3 ADD COLUMN source_commitment BLOB
  CHECK(source_commitment IS NULL OR length(source_commitment) = 32);
ALTER TABLE device_links_v3 ADD COLUMN recipient_random BLOB
  CHECK(recipient_random IS NULL OR length(recipient_random) = 32);
ALTER TABLE device_links_v3 ADD COLUMN source_random BLOB
  CHECK(source_random IS NULL OR length(source_random) = 32);
ALTER TABLE device_links_v3 ADD COLUMN revealed_at TEXT;

-- Unfinished protocol-v3 links have no commitment and can never finish:
-- clients speak only v4 now. Links already approved keep their device and
-- their transfer window (the SAS step is behind them); clients drop the v3
-- native transfer record, so their history copy ends and the user links again.
UPDATE device_links_v3 SET state = 'revoked', revoked_at = CURRENT_TIMESTAMP
WHERE state IN ('pending', 'claimed') AND source_commitment IS NULL;
