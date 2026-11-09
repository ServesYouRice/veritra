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

This capacity run cannot be executed in this environment for the following reasons:
1. **Local platform and Docker daemon unavailable:** `scripts/capacity.sh` is a POSIX Bash script that builds and runs a production container (`busybox:1.37.0`) with CPU and memory cgroups via Docker. On this Windows host, Docker Desktop service (`com.docker.service`) is stopped, connecting to the Docker engine fails (`open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified`), and unprivileged agents cannot start Windows services.
2. **Missing load harness support for 500-member groups:** `scripts/capacity.sh` and `server/cmd/veritra-load` only define tiers `s` (50 accounts, group size 5) and `m` (250 accounts, group size 5). There is currently no command-line flag or profile in `veritra-load` to create or drive a 500-member group fan-out workload.
3. **Delivery budget constraints:** `Limits.Validate()` requires `DELIVERIES_PER_MINUTE >= 2 * (1 + CONVERSATION_MEMBERS)` (1,002 for 500 members). `scripts/capacity.sh` does not pass custom delivery limits to the container, and `veritra-load` has no configuration for a 500-member fan-out test.
4. **Host requirement:** As noted in `STATE.md` and `docs/designs/C8-bigger-communities.md`, Step 2 waits for a capacity run on the owner's Linux host.

The SQLite storage benchmark (`BenchmarkConversationMembersScale` at 500 members: 4.9 ms send fan-out, 1.27 ms member list) was re-verified, but the end-to-end fan-out capacity measurement cannot be run here.

Per specification, the default member limit remains at 250 (`DefaultConversationMembers = 250`).

