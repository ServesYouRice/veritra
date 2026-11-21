# D70 per-group sealed state: Dart-side and SQLite cost

Closes the "Not measured" list in
[`D70-per-group-sealed-state.md`](D70-per-group-sealed-state.md) (Dart-side and
SQLite timings, activation from the database, the format-3 migration).
Measured 2026-11-21 against the real native library (ABI 26) and the real
encrypted SQLite store (`SecureLocalStore`, SQLite3MC), so it is runnable here
and in CI; no device was involved.

## Method

Test: `mobile/test/d70_dart_cost_native_test.dart`. One device ("alice") with
N two-member groups, each made with `initializeConversation` and
`completeCommitBundle` and joined by a second device by Welcome. Then:

- **send**: wall time of `encryptPayload` plus the removal of its pending
  envelope, which includes sealing the change set and the SQLite transaction
  that stores it (median of 20 sends spread over the groups; max in brackets);
- **bytes per message**: sealed bytes whose record generation moved during one
  send (the group record plus the root manifest), read back from SQLite;
- **activation**: `activateSession` of a fresh service over the same open
  store: read every record from SQLite, then the Rust restore. The SQLite read
  alone is timed separately (`loadCryptoSnapshot`);
- **format-3 migration**: `activateSession` over a store holding the checked-in
  format-3 fixture (`crypto/rust/tests/fixtures/state-v3/source.bin`, 34,239
  bytes, 2 groups): the one-time `migrate_v3` plus the first seal.

Command (one process per size):
`D70_GROUPS=<n> VERITRA_CRYPTO_LIBRARY=<lib> flutter test test/d70_dart_cost_native_test.dart`
(without `D70_GROUPS` it runs N = 3 as a smoke check). Groups have two members
only, so the per-group records are small; the Rust measurement
(`D70-per-group-sealed-state.md`, "Measured") covers 100-member groups.

Machine: the shared cloud VM used for the other agents' work, 4 vCPU, Linux
6.18, load average 25 to 38 during the runs (other builds and tests running).
Single run per size, no warm-up: read the milliseconds as an upper-ish bound
and the byte counts as exact.

## Results

| Groups | state bytes (root + records) | bytes per message | send ms, median (max) | activation ms | of which SQLite read | build, s | process RSS | DB files |
|---|---|---|---|---|---|---|---|---|
| 1 | 11,805 | 9,039 | 29.1 (205.9) | 7 | 2 | 0.2 | 173 MiB | 2.6 MB |
| 100 | 852,876 | 13,950 | 13.7 (123.4) | 20 | 8 | 4.7 | 146 MiB | 5.4 MB |
| 1,000 | 8,551,071 | 59,856 | 26.9 (169.2) | 1,693 | 676 | 44.4 | 301 MiB | 13.7 MB |

Format-3 migration: 7 ms (1 group fixture), 23 ms and 10 ms in the later runs
(the same 34 KB fixture each time); not a function of N.

## Reading

- **A message costs one group record plus the root, not the whole state.**
  At 1,000 groups the state is 8.6 MB but one send writes 59.9 KB (0.7%).
  Of that, the root manifest is the larger part and grows with the record
  count (about 53 KB at 1,000 records, the same figure the Rust run found:
  one entry per record). The send time stays flat (13 to 29 ms) from 1 to
  1,000 groups; the machine's load, not N, explains the spread.
- **Activation is the cost that grows with N.** At 1,000 groups it takes
  1.7 s on this loaded host: 0.7 s reading 1,002 sealed records from SQLite
  and 1.0 s on the Dart side and in the Rust restore (the Rust restore alone
  was 260 ms on an idle host). It happens once per app start with a session,
  and is below 25 ms up to 100 groups. A user with 1,000 two-member groups
  would wait about two seconds at launch on a loaded desktop; a phone is
  slower and was not measured.
- **Memory**: the whole test process held 146 to 173 MiB at 1 and 100 groups
  (mostly the Flutter test runtime itself) and 301 MiB at 1,000, about
  150 MiB more, at the end of the run (alice and bob both live).
- **The format-3 one-time migration is cheap** (about 10 to 25 ms for the
  fixture); what it scales with is the old blob's size, and an old blob at
  1,000 groups was over the 32 MiB cap anyway (refused, see the Rust
  measurement).
- **Not a regression gate**: the figures are one run each on a loaded
  shared host. Treat a change of 2x or more as worth investigating, not a
  ±20% movement.

## Still not measured

Real phones (Android and iOS flash storage, key unwrap before the SQLite open),
group sizes above 2 through the Dart path (bytes scale per the Rust table), a
long-running session's RSS, and migration from a format-3 database at 100 or
1,000 groups (such a state cannot exist: format 3 refused above its cap).
