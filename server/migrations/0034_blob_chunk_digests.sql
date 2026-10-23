-- T49B miss 6: per-chunk ciphertext digests for range verification.
--
-- The blob store records a SHA-256 for every 64 KiB chunk next to the
-- whole-blob digest, in the same INSERT as the row, so a range request
-- verifies only the chunks it serves. NULL marks a blob stored before this
-- migration: it is still verified in full on open, and the record built in
-- that pass is stored afterwards. Additive only.

ALTER TABLE attachment_envelopes ADD COLUMN chunk_digests BLOB;
ALTER TABLE backup_blobs ADD COLUMN chunk_digests BLOB;
