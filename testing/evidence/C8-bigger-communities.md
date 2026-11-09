# C8: member limit steps

Evidence for [`docs/designs/C8-bigger-communities.md`](../../docs/designs/C8-bigger-communities.md).
Measured 2026-11-01 on Windows 11, AMD Ryzen 7 7800X3D (16 threads), Go
storage layer on SQLite (the production store), synthetic data.

```text
cd server
go test -run '^$' -bench ConversationMembersScale -benchtime 30x ./internal/storage
```

Test: `server/internal/storage/member_scale_bench_test.go`. One group of N
accounts, each with one device, 50 stored messages.

| Members | Send + fan-out list, ms | List members, ms | Message page (50), ms |
|---:|---:|---:|---:|
| 100 | 5.3 | 0.27 | 0.30 |
| 250 | 3.7 | 0.71 | 0.58 |
| 500 | 4.9 | 1.27 | 0.35 |
| 1000 | 5.2 | 2.99 | 0.35 |

Reading:

- Server write cost does not grow with members: the send transaction is
  dominated by the fsync, not the recipient list (noise is about 2x).
- Member listing grows linearly, about 3 us per member; 3 ms at 1,000.
- The real server cost of a large group is **deliveries**: a message reaches
  every member, so it counts 1 + N against `DELIVERIES_PER_MINUTE`
  (default 1,000). At 250 members that is 4 messages a minute per sender;
  `Validate` already refuses a limit whose budget is under 2 x (1 + N).
- MLS cost at 200 to 1,000 leaves (devices) is in
  [`C0-community-groups.md`](C0-community-groups.md): a join is 206 KB and
  46 ms on the new device at 1,000 leaves, an add commit is 571 B.

Verdict: step 1 (250) passes. 500 and 1,000 are not enabled by default; see
the design.

## Step 2 (500 members) capacity measurement status

Step 2 requires an end-to-end capacity run through `scripts/capacity.sh` with a 500-member group and `DELIVERIES_PER_MINUTE >= 1002` (per [`docs/designs/C8-bigger-communities.md`](../../docs/designs/C8-bigger-communities.md)).

Rechecked 2026-11-09 on the Windows host. This capacity run cannot be
executed here with the existing harness:

1. **Docker engine unavailable.** `Get-Service com.docker.service` reports
   `Stopped`. `docker info --format '{{.OSType}}'` fails with
   `open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified`.
   Bash is installed, but `scripts/capacity.sh` requires a working Linux
   Docker engine for its CPU/memory-limited production container.
2. **No 500-member workload.** The script accepts tiers `s` and `m`; the
   load tool also has a small `smoke` profile. Both capacity tiers use
   `GroupSize: 5` in `server/cmd/veritra-load/workload.go`.
   `parseOptions` supports `-accounts`, but that changes the account count
   without changing group size. No group-size flag or 500-member profile
   exists.
3. **Server limits are not forwarded.** The script's `docker run` passes
   neither `PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS` nor
   `PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE`; exporting them on the
   host does not configure the container. A future run must explicitly set
   members to 500 and deliveries to at least 1,002, as required by
   `Limits.Validate()`, as well as add a 500-member workload. Raising the
   delivery budget alone leaves the container's member limit at 250.

`STATE.md` still tracks the capacity run on the owner's host. No end-to-end
500-member measurement or capacity pass is claimed here.

The storage-only sanity check was run successfully:

```text
cd server
go test -run '^$' -bench ConversationMembersScale -benchtime 5x ./internal/storage
```

At 500 members this rerun measured 2.04 ms send + recipient list, 0.60 ms
member list and 0.23 ms message page (five iterations each). These are
separate from the 2026-11-01 measurements above and do not exercise HTTP,
realtime delivery, rate-limit admission or MLS clients; they cannot qualify
step 2.

Per specification, the default member limit remains at 250 (`DefaultConversationMembers = 250`).
