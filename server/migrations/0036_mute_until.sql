-- W6: timed mute.
--
-- A mute may end by itself: muted_until is the end in Unix seconds, NULL for
-- "always". The push queries treat a row as muted only while muted = 1 and
-- the end has not passed, so an expired mute needs no job and no write, and a
-- device that is offline when it ends is woken again. Additive only: clients
-- that know only the muted flag keep working.

ALTER TABLE conversation_notification_preferences ADD COLUMN muted_until INTEGER;
