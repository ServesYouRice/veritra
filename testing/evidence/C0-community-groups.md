# C0: MLS join and leave cost by group size

Evidence for [`docs/designs/C0-community-groups.md`](../../docs/designs/C0-community-groups.md).
Measured 2026-10-24 on `main` at `dbce0f2` with the crate's own code paths
(`MlsDevice::stage_membership_commit`, `merge_pending_commit`, `join_group`,
`process_commit`; OpenMLS 0.9.2, suite
`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`, ratchet tree in the Welcome,
256-byte padding, two past epochs).

## How

```text
cd crypto/rust
cargo test --locked --release --test c0_join_cost -- --ignored --nocapture --test-threads 1
```

- Test: `crypto/rust/tests/c0_join_cost.rs`. Its quick case (10 leaves)
  runs in every `cargo test`.
- Machine: 4 vCPU Intel Xeon on a shared cloud host. Release profile, rustc
  1.91.0, one test thread. On a shared CPU the absolute times can move by
  about 2x; the bytes are exact.
- **Leaves are devices, not accounts.** D38 allows 10 devices per account,
  so a 100-member community is about 200 leaves at two devices each.
  1,000 leaves is above today's 100-member limit; raising that limit is
  C8's job.
- The group is built the way the app builds it: the creator adds every
  device in one staged commit. Each row then takes the median of five to
  seven runs of the following:
  - **Join.** The creator stages and merges a one-device add. The new
    device processes the Welcome. One existing member processes the
    commit. The new device then decrypts a message, which proves the join
    worked.
  - **Cold remove.** The creator removes the devices it just added, one
    commit each. An add-only commit leaves parent nodes blank, so these
    path-carrying commits encrypt to whole subtrees. This is the worst
    case, right after a bulk build.
  - **Warm remove.** A fresh group of the same size gives every member a
    state. Every even leaf commits one self-update, which every member
    processes, so no parent node is blank. Then one removal is made.
    This was not run at 1,000 leaves, where warming costs about
    O(N²) commit processing (around an hour).

## Results

Run 1 (run 2 in brackets where it differs by more than 20 %).

| Leaves | Add: stage ms | Add: merge ms | New device: Welcome ms | Member: commit ms | Add commit B | Welcome B | Bulk Welcome B |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 | 0.39 | 0.07 [0.17] | 0.79 | 0.27 [0.45] | 571 | 3,167 | 3,307 |
| 100 | 0.93 | 0.35 | 4.78 | 0.86 | 571 | 21,441 | 32,201 |
| 200 | 1.52 | 0.68 | 9.47 | 1.46 | 571 | 41,736 | 64,499 |
| 1000 | 7.15 | 3.62 | 45.98 | 7.33 | 571 | 205,736 | 322,899 |

| Leaves | Cold remove, first: stage ms / member ms / B | Cold remove, median | Warm remove |
|---:|---|---|---|
| 10 | 4.10 [2.06] / 0.64 / 1,851 | 1.01 / 0.65 / 1,595 | 0.82 / 0.55 / 1,083 |
| 100 | 4.37 / 4.29 [1.20] / 9,275 | 4.20 [6.29] / 1.26 / 9,019 | 2.07 / 1.60 / 1,595 |
| 200 | 12.47 / 3.37 [2.01] / 17,469 | 10.88 [14.42] / 3.50 [2.05] / 17,213 | 4.00 / 2.87 / 1,595 |
| 1000 | 38.47 [22.58] / 9.15 / 83,261 | 49.97 [22.09] / 10.15 / 83,005 | not run |

Reading:

- **An add commit is 571 bytes at every size.** An add-only commit carries
  no update path.
- **The Welcome grows by about 206 bytes per leaf,** because it carries the
  ratchet tree. Processing it costs about 46 µs per leaf (leaf signature
  checks and tree hashing). One join into a 1,000-leaf group is about
  206 KB and 46 ms on the new device.
- **Each existing device pays about 7 µs per leaf** to process an add
  commit (7.3 ms at 1,000).
- **A removal right after a bulk build is about 83 bytes per leaf** (83 KB
  at 1,000). Once the tree is warm, a removal is about 1.6 KB, in line
  with the log-sized update path.

## Layouts compared

The numbers come from the tables. Groups between measured sizes are
interpolated linearly. The joiner may enter every channel, and the member
commits are the add commits above.

**Community S:** 100 members on 2 devices each (200 leaves). It has 15
open channels and 3 private channels of 40 leaves.

| Per join of one device | One group per channel | Shared group + per private channel |
|---|---:|---:|
| Groups joined | 18 | 4 |
| Welcome bytes downloaded | ≈ 653 KB | ≈ 69 KB |
| New device CPU | ≈ 148 ms | ≈ 16 ms |
| Commits each existing open-channel device processes | 15 (≈ 22 ms, 8.6 KB) | 1 (≈ 1.5 ms, 0.6 KB) |
| Committer CPU | ≈ 35 ms | ≈ 4 ms |
| Leave, warm tree: commit bytes each device fetches | ≈ 24 KB (15 commits) | ≈ 1.6 KB, plus each private group the leaver was in |
| Leave, cold tree | ≈ 262 KB | ≈ 17 KB |

**Community L:** 500 members on 2 devices each (1,000 leaves). It has 30
open channels and 5 private channels of 200 leaves.

| Per join of one device | One group per channel | Shared group + per private channel |
|---|---:|---:|
| Groups joined | 35 | 6 |
| Welcome bytes downloaded | ≈ 6.4 MB | ≈ 414 KB |
| New device CPU | ≈ 1.43 s | ≈ 93 ms |
| Commits each existing device processes | 30 (≈ 220 ms, 17 KB) | 1 (≈ 7 ms, 0.6 KB) |
| Leave, cold tree | ≈ 2.5 MB | ≈ 83 KB |

With 50 joins a day in community L, one group per channel costs every
existing device about 11 s of CPU and 0.9 MB a day for joins alone. The
shared layout costs about 0.4 s and 29 KB.
