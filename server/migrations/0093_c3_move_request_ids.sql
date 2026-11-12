-- C3 channel conversion, review residual of L-6 (docs/crypto.md, "C3 channel
-- conversion"): the id the mover's device chose for its move request. A
-- repeated request is answered as the same move only when it carries the
-- same id, so another device of the same account never adopts this move and
-- sets the new group up a second time. Never sent to anyone; NULL for moves
-- from before this migration, which no request can replay.
ALTER TABLE c3_channel_moves ADD COLUMN request_id TEXT
  CHECK (request_id IS NULL OR length(request_id) BETWEEN 22 AND 128);
CREATE UNIQUE INDEX c3_channel_moves_request
  ON c3_channel_moves(channel_id, moved_by, request_id)
  WHERE request_id IS NOT NULL;
