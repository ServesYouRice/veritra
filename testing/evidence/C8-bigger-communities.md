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
