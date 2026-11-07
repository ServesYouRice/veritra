# C5 server moderation (2026-11-07)

Migration 0055. Counters used: migration 0055 only; local schema 23 unused.

Checked by tests: kick and ban rank rules (member, moderator vs peer or
admin, self); ban = removal + row in one transaction, no add, no channel add,
no join request, unban re-adds nothing, pre-banning a non-member needs an
admin; timeout bounds, rank, expiry, early clear, replay of an earlier post
still answers; slow mode gap, exemption of moderators and above, per sender,
off; paused invites refuse preview and request for a community only; audit log
read rights; HTTP routes and status codes. Mutation check: disabling the
timeout and slow-mode call fails both tests.

Commands: `go vet ./internal/...`, `go test ./internal/storage
./internal/httpapi`, full `go test ./...` in the check script.
Not built: apps, delete-others, escalation (see the C5 design status).
