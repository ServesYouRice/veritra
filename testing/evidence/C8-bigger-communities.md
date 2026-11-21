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

## Step 2 (500 members): repo-side readiness and container numbers (2026-11-21)

**These are container numbers, not the owner-host run the design asks for.**
Step 2 stays unproven. Nothing here changes the default.

### What was made ready

- `server/cmd/veritra-load`: a `c8` profile (one group of every account, no
  DMs, no attachments), flags `-group-size` and `-groups`, and seeding that
  finishes a group above 100 through `POST /conversations/{id}/members`
  (creating a conversation names at most 100 others). This closes blockers 2
  and 3 above. Tests: `main_test.go` (flags; a 105-member group seeded and
  sent into by all 105 accounts).
- `scripts/capacity.sh`: tier `c8` (the m container, member limit 500,
  deliveries 1,002), server settings forwarded to the container
  (`VERITRA_CAPACITY_SERVER_ENV`; blocker 3), and `VERITRA_CAPACITY_HOST=1`
  for a host process where Docker cannot run (load scenario only). It also
  prints the host load average at the end, so a noisy run can be recognised.
- Owner-host command (Docker, `m` container: 2 CPUs, 2 GiB):

  ```sh
  scripts/capacity.sh c8 load -accounts 500 -group-size 500 -online 500 \
    -rate 0.1,0.25,0.5 -warmup 15s -duration 60s
  ```

  Pass means verdict PASS at some step (send and sync p95 <= 150 ms, p99 <=
  500 ms, errors <= 0.1%, realtime delivery p99 <= 2 s), with the host quiet.
  Do not run it beside other work.

### Finding: seeding a 500 group at the 1,002 budget takes hours

Every write reserves `1 + member limit` deliveries (501 at limit 500), so
at 1,002 a minute an account can make 2 writes a minute. The 400 member adds
the seed needs therefore take about 200 minutes. The tool retries 429s and
would finish, but for a quick run raise the budget for the whole run:
`VERITRA_CAPACITY_SERVER_ENV=PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE=100000`.
Steady-state senders in these runs stay far below 2 messages a minute, so the
budget does not bind the measured window; the budget at the floor itself is
covered by `Limits.Validate` and its tests, not by a run.

### Method of the container runs

- **Host:** shared 4 vCPU Linux container, 15 GiB RAM, with other agents
  building and testing at the same time. The **host load average was 11 to 34
  on 4 CPUs** during the runs (recorded per run below), so latencies are
  pessimistic and noisy. Docker was not available (no daemon), so the server
  ran as a **host process** (`VERITRA_CAPACITY_HOST=1`, `GOMEMLIMIT=1500MiB`),
  production mode, SQLite, JSON logs on, no CPU or memory limit. The load tool
  ran on the same machine.
- `PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS=500` (250 for the reference),
  deliveries 100,000 (seeding; see above), synthetic data, no attachments,
  no companions, no cold catch-ups.

### Results (client-side ms; one group; each step 15 s warm-up, 60 s measured)

A and B: same server, same 100 online devices, same rates; only the group
size differs. Every other member is offline (a stored delivery, no socket).

| Group | msgs/device/min | send p95 / p99 | sync p95 / p99 | realtime delivery p99 | errors | verdict |
|---|---|---|---|---|---|---|
| 250 (A) | 0.5 | 183 / 283 | 201 / 295 | 443 | 0 | miss: send p95, sync p95 |
| 250 (A) | 1 | 130 / 214 | 230 / 322 | 491 | 0 | miss: sync p95 |
| 500 (B) | 0.5 | 79 / 223 | 256 / 431 | 503 | 0 | miss: sync p95 |
| 500 (B) | 1 | 99 / 181 | 207 / 291 | 411 | 0 | miss: sync p95 |
| 500 (B) | 2 | 95 / 258 | 195 / 255 | 5,560 | 1.2% (429, per-address) | miss: errors, delivery |

- Host load average at the end: A 16/17/22, B 11/18/23 (1/5/15 min, 4 CPUs).
- Server: Go memory 32-36 MB in both; writer acquire mean 2-4 ms, mean
  writer queue 0.08-0.27; process peak RSS 411 MiB (mostly seeding), CPU peak
  110% (B) and 142% (A) of one core; 0 5xx, 0 dropped realtime events,
  0 missing messages after the run. Data directory 8-10 MB.
- **Reading:** at equal online devices a 500-member group costs about what a
  250-member group costs; the differences are inside the noise, and both
  miss the 150 ms sync p95 on this loaded host (A misses it too, and 250 is
  today's default). The step at 2 messages/device/min missed on the per-address
  general limit (240 requests/minute; each device syncs about 290 a minute),
  as tier S did at 16 in T47: a tool and limit effect, not group size.
- **500 online (C):** all 500 members online at 0.1, 0.25 and 0.5 msgs/device/min
  missed every target by seconds (send p95 6-23 s, 30 s delivery deadline
  hit), with the host load average at 34. Server CPU averaged under one core
  and the writer queue was long in the first step, so the generator (500
  sockets and about 100 sync GETs/s on the same 4 CPUs) and the other
  agents' work starved the server. **This run says nothing for or against
  500**; it shows this container cannot host the 500-online case, which is
  why the design asks for the owner's host.
- The storage layer on its own (run again, `-benchtime 20x`, same host): send
  plus recipient list 2.5 ms at 500 and 2.7 ms at 1,000 (3.2 ms at 250);
  member list 1.6 ms at 500, 3.4 ms at 1,000; message page 0.4-0.8 ms.
  Unchanged from the table above.

### Verdict

The container numbers show no growth in server cost from 250 to 500 members
at equal online devices, and nothing that argues against 500. They cannot
qualify step 2: the host was far from quiet, the 500-online case could not be
measured, and the design requires the owner's host. **No default change is
proposed from these numbers.**

If the owner's run passes, step 2 changes two defaults together, because
startup refuses a member limit whose budget is under `2 x (1 + limit)`:
`DefaultConversationMembers` 250 to 500 and `DefaultDeliveriesPerMinute` 1,000
to at least 1,002 (`server/internal/config/limits.go`), with the
`docs/operations.md` limits table and STATE decision D80/D38 text.
