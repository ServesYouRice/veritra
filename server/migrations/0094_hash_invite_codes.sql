-- Registration invite codes are bearer credentials: anyone who reads the
-- database or a backup could register with a stored code. Keep only
-- SHA-256(code) (the hex auth.HashToken gives session tokens), computed by
-- veritra_invite_code_hash, which the server registers in Go
-- (server/internal/storage/invite_code_hash.go). Existing invites keep
-- working: a code still redeems because the server hashes what it is given
-- and looks the hash up.
--
-- In place, not a table rebuild: dropping invites would cascade-delete the
-- enrollment reservations that reference it (foreign keys are on), and
-- SQLite cannot drop a UNIQUE column. Renaming keeps the NOT NULL UNIQUE
-- constraint and its index, now over the hashes. A hash (64 lowercase hex)
-- does not look like a code (26 base32 capitals), so rows hashed first cannot
-- collide with rows not yet hashed.
UPDATE invites SET code = veritra_invite_code_hash(code);
ALTER TABLE invites RENAME COLUMN code TO code_hash;
