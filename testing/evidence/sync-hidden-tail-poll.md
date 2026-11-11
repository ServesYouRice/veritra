# Hidden tail on every poll: before and after (TASK-209)

Date: 2026-11-11. Local, Windows 11, AMD Ryzen 7 7800X3D, Go SQLite, no network.

Opt-in: `GET /api/v1/sync/events?...&scan=bounded` (the app sends it). The
response adds `scanned_through` and `scan_truncated` (same names as the scoped
conversation route, D92); a 200 leaves out `oldest_event_id` and
`latest_event_id` (only the 409 carries them, and only the epoch is read
cheaply). Without the parameter nothing changes.

Command: `cd server && go test -run '^$' -bench 'SyncHiddenTailPoll|SyncHiddenRun/40000x2/blocked/SyncBounds' ./internal/storage`

| Case (trailing run of blocked events behind the cursor) | Before | After |
|---|---|---|
| Poll, 10,000 hidden events | 54.7 ms (every poll) | 0.35 ms (cursor already past the run) |
| Poll, 40,000 hidden events | 231 ms (every poll) | 0.36 ms |
| `SyncBounds` added to each 200 page, 40,000 hidden x2 | 460 ms | not run on a bounded 200 (epoch only) |

"After" is a poll once the client has moved its cursor to `scanned_through`.
The first crossing of the run still costs the scan, one 2,000-candidate budget
per request, so each request is bounded. The first crossing is not in the
table.

Noise: one machine, a few runs; read the order of magnitude, not the digits.

Behaviour: a block-hidden run that the cursor passes is not replayed after an
unblock (D92, as on the scoped route). Tests:
`server/internal/storage/sync_bounded_scan_test.go`,
`server/internal/httpapi/sync_bounded_contract_test.go`, the TASK-209 group in
`mobile/test/app_state_catch_up_test.dart`.
