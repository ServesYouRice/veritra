-- C2: who may post in a conversation. 'everyone' is the default; 'admins'
-- limits posting to the owner and admins. Announcement channels are always
-- restricted, derived from channels.kind at send time, so no backfill.
ALTER TABLE conversations ADD COLUMN posting_policy TEXT NOT NULL DEFAULT 'everyone' CHECK (posting_policy IN ('everyone', 'admins'));
