# C5 app screens (2026-11-08)

API client, state calls, member menu (kick, ban, timeout with a length, lift
timeout) and a Moderation screen (pause or resume invitations, slow mode per
channel, banned accounts with lift, activity log). Server additions:
`GET /communities/{id}/moderation-state`, kick and ban responses carry the
per-channel removal events, and the C1 community remove route now writes a
`kick` audit row (coordinator answer 3). No local schema used. Strings in
English and Serbian (Latin generated). Tests: `membership_api_test`,
`membership_screens_test` (moderation group), Go `moderation_handlers_test`.
Not done: app-side enforcement of bans and timeouts (waits for C4's record).
