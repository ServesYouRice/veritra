-- C1 invitation binding v2: the creating device's signature.
--
-- Migration 0048 stored binding_tag, a MAC keyed from the link secret. Anyone
-- holding the link can compute that tag, so a server that colludes with a
-- link holder could swap the target and recompute it. v2 adds an Ed25519
-- signature by the creating device's credential key (ABI 13 sign, domain
-- veritra-invite-binding-v2) over the origin, the target, the inviting
-- account and device, that device's key and the link's locator. The joiner
-- verifies it against the key the link commits to and, where it has the
-- group, the MLS roster key. The server stores and returns the 64 bytes and
-- cannot check them (it does not know the origin the link names); the tag
-- stays, so every row keeps its shape.
--
-- Rows made before this migration have no signature (NULL). A v2 app refuses
-- them (fail closed) and they expire like any invitation; nothing here
-- touches them. New invitations must carry one (the store refuses a row
-- without).

ALTER TABLE membership_invites ADD COLUMN binding_signature BLOB CHECK (binding_signature IS NULL OR length(binding_signature) = 64);
