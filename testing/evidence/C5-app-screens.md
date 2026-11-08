# C5 app screens (2026-11-08)

API client, state calls, member menu (remove, ban, timeout with a length, lift
timeout; the remove item is the C1 route, which now audits as a kick) and a Moderation screen (pause or resume invitations, slow mode per
channel, banned accounts with lift, activity log). Server additions:
`GET /communities/{id}/moderation-state`, kick and ban responses carry the
per-channel removal events, and the C1 community remove route now writes a
`kick` audit row (coordinator answer 3). No local schema used. Strings in
English and Serbian (Latin generated). Tests: `membership_api_test`,
`membership_screens_test` (moderation group), Go `moderation_handlers_test`.
Not done: app-side enforcement of bans and timeouts (waits for C4's record).

Opus review fixed: moderation-state hid private channels from non-members (Go test); single menu button (no overflow); invitations tile; lift ban only for admins and above; the activity log request only for admins; a Serbian wording fix. Known: `slow_mode` audit rows carry the channel id (admins only; pre-existing from the server half); send retries ignore Retry-After (app-side checks follow-up).
