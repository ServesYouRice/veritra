# T47 capacity contract and T49D admission evidence

Card I47 (and the T49D evidence it feeds). The contract, alerts and
runbooks are in `docs/operations.md`, "Capacity alerts and runbooks".
All data is synthetic: generated accounts, random ciphertext.

## Method

- **Host:** shared 4 vCPU Intel Xeon, 15 GiB RAM, Linux 6.18, Docker 29.9;
  five other agents were building and testing at the same time (load average
  5-10), so absolute numbers are pessimistic and noisy. The load generator
  ran on the same host, outside the container.
- **Server:** the commit under test, `CGO_ENABLED=0` build, production mode,
  in a busybox container limited with `--cpus`/`--memory` (tier S: 1 vCPU,
  1 GiB; tier M: 2 vCPU, 2 GiB), data on the host's disk, JSON request logs
  on. Trusted proxy = Docker's bridge, so each simulated device has its own
  `X-Forwarded-For` address.
- **Tool:** `scripts/capacity.sh <tier> <scenario> [flags]` builds the
  server and `server/cmd/veritra-load`, seeds the tier's dataset through the
  public API, runs the workload model described in `docs/operations.md`,
  scrapes `/metrics` before and after each measured window, and checks every
  acknowledged message afterwards. Each step: 15 s warm-up, 60 s (load) or
  90 s (scenarios) measured. Latencies are client-side.
- **Longer runs** (soaks of hours, tier M scenarios) are for the owner's
  host: `scripts/capacity.sh s load -rate 4 -duration 2h`.

Commands:

```sh
scripts/capacity.sh s load -rate 1,4,8,16 -warmup 15s -duration 60s
scripts/capacity.sh s restart -rate 4 -warmup 15s -duration 90s
scripts/capacity.sh s backup -rate 4 -warmup 15s -duration 90s
scripts/capacity.sh m load -rate 1,4,8 -warmup 15s -duration 60s
scripts/capacity.sh m load -rate 1,2,4 -cold 0 -warmup 15s -duration 60s
cd server && go test -race -run Scenario -v ./internal/app
cd server && go test -run '^$' -bench MembershipsPerAccount -benchtime 20x ./internal/storage
```

## Tier S: stepped load (50 accounts, 75 clients, 20k-message history)

Client-side ms; "deliveries" are realtime events received by other devices.

| msgs/device/min | msgs/s | sync GET/s | send p95/p99 | sync p95/p99 | list p99 | delivery p99 | cold page p99 | errors | verdict |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 0.7 | 7 | 37 / 64 | 23 / 59 | 91 | 66 | 96 | 0 | pass |
| 4 | 2.5 | 26 | 13 / 39 | 21 / 41 | 19 | 49 | 84 | 0 | pass |
| 8 | 5.8 | 56 | 10 / 14 | 18 / 27 | 18 | 16 | 82 | 0 | pass |
| 16 | 13.8 | 128 | 36 / 96 | 23 / 76 | 98 | 96 | 93 | 3.7% (429) | miss |

- Server side at 8: writer acquire p99 <= 10 ms, mean writer queue 0.006,
  Go memory 19 MB, 0 dropped realtime events, 0 5xx. Container CPU 6-19%
  of one core at 8 and 20-50% at 16; peak 92% only while seeding (bcrypt).
- The step at 16 missed only on errors, all of them 429 from the per-address
  general limit (240/min): a device and its companion client share one
  address, and at 16 msgs/device/min in groups of 5 each client makes about
  100 sync requests a minute. Server latency still met every target.
- **Rating:** half the highest passing step: 4 msgs/device/min for 50
  accounts and 75 clients, about 3 msgs/s and 10 deliveries/s.

## Tier S: restart and backup scenarios (4 msgs/device/min)

| Scenario | Result |
|---|---|
| `docker restart -t 30` a third into the window | ready again in about 1 s; 1 failed send out of about 3,500 requests; no second without a successful request; all 75 sockets reconnected (connect p50 52 ms); verify: 0 of 332 acknowledged messages missing; pass |
| `scheduled-backup` (VACUUM INTO, blob copy, restore drill) during the load | finished in 2 s on 309 MB; send p99 81 ms and delivery p99 116 ms (from 20 and 17 ms); writer acquire p99 <= 25 ms; container memory peak 301 MiB (page cache); pass |

## Tier M: stepped load (250 accounts, 375 clients, 100k-message history)

Steady state, without cold catch-ups (`-cold 0`):

| msgs/device/min | msgs/s | sync GET/s | send p95/p99 | sync p95/p99 | list p99 | delivery p99 | errors | verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | 4.3 | 42 | 11 / 31 | 23 / 36 | 31 | 30 | 0 | pass |
| 2 | 7.8 | 78 | 32 / 110 | 82 / 224 | 20 | 94 | 0 | pass |
| 4 | 14.8 | 151 | 12 / 17 | 25 / 38 | 26 | 16 | 0 | pass |

Container CPU 15-55% of one core (2 available), Go memory 45-56 MB,
373 sockets, writer acquire p99 <= 50 ms, no dropped events. The noisy
step at 2 is host contention (it is slower than the step at 4).

With the full model (a fifth of the devices catch up once from the middle
of history in each window):

| msgs/device/min | sync p95/p99 | cold page p50/p99 | send p99 | verdict |
|---|---|---|---|---|
| 1 | 282 / 652 | 115 / 1114 | 267 | miss |
| 4 | 163 / 563 | 171 / 1330 | 313 | miss |
| 8 | 612 / 1034 | 471 / 1649 | 346 | miss (CPU about 75% of 2 cores) |

A cold catch-up from the middle of a 100k-event history pages through later
instance events (T49's open `ListSyncEvents` cursor item, 252 ms per page in
the benchmark); the bursts take whole cores and slow every other sync.
**Rating:** 2 msgs/device/min for 250 accounts (half the highest steady
step), valid while few devices catch up from deep history; the full model
needs the T49 cursor follow-up first. No 5xx and no lost message in any run
(verify: 3,346 and 1,905 acknowledged messages, none missing).

## Provider stall and restart with wake work in flight

`go test -race -run Scenario ./internal/app` (push send deadline 50 ms and
retry delay 100 ms instead of 10 s and 5 s; the bounds scale with them):

- **Provider stall:** 200 wake jobs, provider hangs until the deadline. No
  job delivered or lost during the stall; at most 8 concurrent sends; the
  backlog and oldest-job gauges show the stall. After recovery all 200 jobs
  drained in 0.8 s, none abandoned.
- **Restart:** worker stopped with 8 sends in flight. All 100 jobs survive;
  the new process sends the unleased ones at once and the leased ones only
  after their 30 s lease (simulated), then delivers all 100.

## Cost model for admission limits (T49D)

| Resource | Measured cost | Source |
|---|---|---|
| One 1 KiB message | 3.8 KiB of database (envelope, sync event with a base64 copy, indexes) | 10k messages through the API |
| One realtime delivery | about 4-10 ms of server CPU (the app's catch-up is two sync GETs per event) | tier S CPU at 8 and 16 msgs/device/min |
| Memberships per account, 200 / 1000 / 2000 | SyncBounds 2.3 / 14 / 28 ms; sync page from mid 2.7 / 18 / 30 ms; conversation list 3.1 / 6.7 / 16.6 ms | `BenchmarkMembershipsPerAccount` |
| Live blob data | a backup run peaks at (keep + 3) x live, 10x with keep 7; the 40 GiB PVC holds about 3.6 GiB live | backup and drill code paths |
| Socket | 10 per account, 3 per device, 20 per address (hub limits) | `internal/realtime/hub.go` |

Observations, not changed here: read-only transactions such as
`ListConversationMembers` use the writer pool, so they count as writer
waits; the per-address limit, not the server, bounds a busy household
behind one NAT.

## T49D: limits derived from the cost model

| Limit | Default | Evidence |
|---|---|---|
| Instance storage | volume x 0.9 / (keep + 3), at most 10 GiB (3,686 MiB on the 40 GiB PVC) | the backup disk budget above; the former fixed 10 GiB needed about 100 GiB |
| Account storage | 512 MiB (at most the instance limit) | about a seventh of the S instance budget |
| Blobs per account | 10,000 | each blob takes at least 4 KiB; the flat blob directory scan is linear (T49: 179 ms at 100k) |
| Devices per account | 10 | the hub's 10 sockets per account |
| Open device links | 3 | a claimed link holds a key package before it has a device row |
| Members per conversation | 100 | the existing create cap; 100 deliveries per message is 0.4-1 CPU-s on tier S |
| Conversations per account | 1,000 | sync page 14-18 ms at 1,000 memberships, 28-30 ms at 2,000 |
| Deliveries per account | 1,000 a minute | 17/s, a third of the 47/s tier S served within latency targets |
| Stored bytes per account | 64 MiB an hour | 3.8x database growth per ciphertext byte: at most about 240 MiB an hour per account |
| Write guard | refuse writes below the smaller of 5% and 2 GiB free | VeritraDataDiskLow pages at 10% first |

**Tier S rerun with the limits on** (`-rate 4,16`): step 4 passed (send
p99 10 ms, sync p99 12 ms, cold page p99 64 ms); step 16 again missed only
on per-address 429s (28 of about 8,300 requests), none from the new write
budget; no 5xx, 0 of 1,069 acknowledged messages missing. Seeding 20k
messages took 2m25s instead of about 1 min: bulk writes through the API
run at the per-account delivery budget (the tool waits on 429).

Checks: `go test -race ./internal/admission ./internal/storage ./internal/httpapi
./internal/app ./internal/config ./cmd/...` (limit boundaries, a refused
approval leaves no device, eight concurrent writers for one free slot -> one
wins, a full third party gives the same error as a block, a community add
needs room in every channel, budget reservation under 200 parallel
requests, settlement by published recipients, 429 with `Retry-After`, the
disk guard, derived defaults and the startup log, `doctor`'s warning).
Migration 0033 adds three indexes so each count reads only the account's or
community's rows.

**Strong review (advisor), adopted:** count blobs as well as bytes; bound
open device links; refuse device links early and still allow removing a
device; check the largest channel when a community grows; check the added
account's conversation count but answer 403 as for a block; derive the
instance default from the volume instead of cutting it to a fixed 3 GiB, log
it and warn in `doctor`; cap devices at the hub's 10 sockets; require
deliveries >= 2 x (1 + members); reserve before the transaction and settle
after; meter edits, deletes, reactions, MLS messages and commits, calls,
member changes and community adds; add a per-account bytes budget and a
low-disk write guard. **Not adopted:** a limit on active invites (only
owners and admins create them); communities per account (channel creation
already counts against the creator's conversation limit); the client
showing 507 to the user (mobile, not in this card). **Noted:** a community
add refused because a channel the caller cannot see is full reveals that
some channel is full, not which or whose; the per-address limit for
households behind one NAT is a separate card.

## Tier M rerun after the ListSyncEvents fix (2026-10-23)

The T49 cursor follow-up (`ListSyncEvents` from a mid-history cursor:
172 ms -> 2.1 ms per page in `benchmarks-t49.md`) at commit `b2e3ee9`.
Same tool and full model (a fifth of the devices catch up once from the
middle of history in each window):

```sh
scripts/capacity.sh m load -rate 1,4,8 -warmup 15s -duration 60s
```

Host: the same class of shared 4 vCPU Xeon, 15 GiB, but much less loaded
than the runs above (load average about 1-2 instead of 5-10), Docker 29.9
with `busybox:1.37.0` from `mirror.gcr.io` (Docker Hub refused the pull
with 429). Seeding 100k messages and 1,000 attachments took 3m54s; the
whole run about 8 minutes. Client-side ms:

| msgs/device/min | msgs/s | sync GET/s | send p95/p99 | sync p95/p99 | list p99 | delivery p99 | cold page p50/p99 | errors | verdict |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4.3 | 42 | 31 / 38 | 22 / 30 | 43 | 39 | 10 / 43 | 0 | pass |
| 4 | 12.7 | 128 | 15 / 46 | 42 / 200 | 29 | 49 | 10 / 41 | 0 | pass |
| 8 | 31.2 | 320 | 44 / 113 | 71 / 185 | 122 | 117 | 14 / 100 | 0.05% (9 sync 429s) | pass |

Before (the full-model table above): cold page p50/p99 115/1114,
171/1330 and 471/1649 ms, and every step missed. Cold pages now stay
under 100 ms at p99 and no longer slow the other syncs.

- Server side: writer acquire p99 <= 25 ms at 1 and 4, <= 100 ms at 8;
  Go memory 50-54 MB; 373 sockets; 0 dropped realtime events; 0 5xx.
  Container peak 185% of one core (2 available, at 8) and 455 MiB.
- The nine 429s at 8 came from the per-address limit (a device and its
  companion share an address; same account, so the shared-address change
  does not lift them).
- Verify: 3,355 acknowledged messages checked, 0 missing, 0 unreadable.
- **Rating:** half the highest passing step: 4 msgs/device/min for 250
  accounts and 375 clients (about 13 messages/s) with the full model,
  cold catch-ups included (was 2, valid only while few devices caught up).
  The host was quieter than for the earlier runs, so part of the gain is
  the host; the benchmark isolates the query. A long soak and a rerun on
  the owner's host are still open.
