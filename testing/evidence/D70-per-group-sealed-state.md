# D70 per-group sealed state: what was built and tested

Status (as STATE.md records it): S1 to S3 built and Opus-reviewed with no
blockers; S4 built and Opus-reviewed, with review fixes in `b939215`; S5 done
under D73. The leave/Welcome race follow-up is built in this change and not
yet reviewed. Sources: the commit history and the test files named below. Test
counts are counted from the source (`#[test]`, `test(`), not from a run, and
each native Dart file includes one guard test that only fails when CI lacks
the native library. The Rust and Dart suites run in CI; this change was made
where Flutter and Docker are unavailable. No timing, byte or memory
measurement was taken for D70 (see "Not measured").

Design: [`D70-per-group-sealed-state.md`](../../docs/designs/D70-per-group-sealed-state.md).
Crypto change log and the "Rejoining a conversation" note: `docs/crypto.md`.

## S1: Rust storage (format 3 unchanged)

Commits `e545f43`, `20bafd2`, `7df311b`, `a67db55`, `6c065a6` (merge `cff9489`).

- OpenMLS storage split by owner behind a scoped provider
  (`crypto/rust/src/mls/storage.rs`): device, per group, per key package; a
  scope guard refuses a group-keyed call for another group and an unscoped
  key-pair write. Key-package lookup goes straight to its partition by the
  serialized hash reference (`serde_json`, D76).
- A classifier files every key of a flat format-3 map to its owner and fails
  closed on an unknown, malformed or ambiguous key.
- A genuine format-3 state from the pre-split build is checked in as a fixture
  (`crypto/rust/tests/fixtures/state-v3/`, with its generator).
- Tests, `crypto/rust/src/mls/storage_tests.rs` (7): id parser matches the
  OpenMLS serializer; classifier refusals; each operation touches only its own
  owners; no standalone key pair survives any device operation (the design's
  leak premise was corrected to this); scope guard; every storage method is
  routed; a Welcome with many bogus secrets costs one lookup each.

## S2: local schema 16

Commits `b7497eb`, `6788c75`, `b78e5a0`, `2e85d8e` (merge `a32709d`).

- Table `local_crypto_records(kind, record_id, generation, sealed)`,
  `LocalStore.loadCryptoRecords`, in-memory store parity. The table sat unused
  until S3. The local schema is now 17 (K2 took the next number; D70 did not
  need another).
- Tests, `mobile/test/d70_crypto_records_schema_test.dart` (11): fresh create
  has the table; 15 to 16 upgrade keeps crypto state and history; a failed
  upgrade rolls back and the next open retries; records read back ordered by
  kind then id bytes; every path that clears or replaces the crypto-state
  singleton (identity change, backup restore, clear, quarantine reset) clears
  the records, and cached-state clear and same-identity sign-in keep them.

## S3: format 4, ABI 10, app wiring

Commits `c1a9b78`, `79dc32e`, `90eb7af`, `9546689`, `103858d`, `d5bc8c5`
(merge `a363c91`).

- Format 4: one sealed record per owner under one root manifest; one counter
  (the generation). `seal_changes` seals only changed records; restore goes
  through `restore_begin` / `restore_add` / `restore_finish` and refuses a
  stale, missing, extra, foreign or tampered record. Per-record caps replace
  the 32 MiB total (`crypto/rust/src/mls/records.rs`: root 16 MiB and 200,000
  entries, device 1 MiB, group 32 MiB, 4 MiB per value, 10,000 values, key
  package 256 KiB, pool 1,000). A record over its cap returns `-8` and names
  the record, keeping the change set.
- Also: `migrate_v3` (one-way, compare-and-swap commit in Dart), `group_delete`,
  key-package expiry pruning, D74 (`welcomeKeyPackageUnavailable`).
- Rust tests, `crypto/rust/src/mls/records_tests.rs` (16) and
  `crypto/rust/src/ffi/records_tests.rs` (5): fresh device seals every record
  and restores; each operation reseals only its own records; restore refusals;
  only format-4 roots open; generation rule; own removal and `group_delete`
  drop the record; pruning drops only long-expired packages; a full pool is
  refused; an oversized group names itself; D74 unavailable Welcome; genuine v3
  and v2 fixtures migrate and keep working; migration needs the stored counter
  and identity; a crash at each migration step leaves v3 intact and reruns;
  owned standalone pairs are filed, the rest dropped, unknown labels refused;
  random restarts match a twin that never restarts; the FFI loader refuses
  incomplete, extra and stale states.
- Dart tests: `d70_crypto_records_changes_test.dart` (11, changes applied
  atomically with the root, stale transition writes nothing, failure rolls
  records back, crash at each stage leaves the old state whole, migration
  compare-and-swap) and `d70_native_records_service_test.dart` (8, against the
  native library: restart restores, v3 migrates once at activation, gone
  group settles (D54), D74 notice, retryable first activation, delete,
  prune). `rejoin_after_removal.rs` (5) covers rejoin after the group drop.

## S4: app wiring

Commits `130bb71`, `5d75c0a`, `b939215` (merge `645030a`).

- A caught-up foreground pass prunes expired key packages (at most every 6
  hours); replenishment prunes first and keeps a partial batch.
- Leaving drops the conversation's unsent messages and notes the leave
  durably; the next foreground pass drops the MLS group and its queued MLS
  messages before reading events. A Welcome for a conversation still in the
  note first runs the user's deferred leave.
- `-8` becomes `CryptoRecordLimitExceeded`: a localized message (en, sr,
  sr_Latn) and a `recordLimit` sync stop that offers to leave that chat.
- Tests: `d70_s4_wiring_test.dart` (prune throttling, leave and drop, failed
  drop retried, re-add Welcome ordering, note write failure, D74 with note,
  record-limit stop and leave, localization), `d70_s4_native_test.dart` (6),
  `d70_s4_record_limit_native_test.dart` (3), `d70_s4_wake_test.dart` (1, a
  wake hands a re-add Welcome to the foreground), `d70_s4_banner_test.dart` (2).

## S5: backups (D73)

Commit `50bee42` (merge `38fa087`).

- Under D73 backups carry no MLS state, so VBK2 and backup JSON v6 did not
  change. Tests, `d70_backup_records_test.dart` (3): a backup holds no root,
  record or state key; a restore over a device with records leaves none; an
  old backup with a crypto state restores none.

## Follow-up: a leave racing an older add-Welcome (this change)

Race: a pass fetched an add-Welcome, the user left, the pass then applied the
Welcome after the group drop had cleared the note, and the group came back.

- The `DELETE /members/me` response now carries `event_id`, the id of the
  leaver's own `membership.left` sync event (additive field; no schema
  change). The app stores it as that conversation's floor in the local setting
  `mls.left_floors`, written before the leave note. Welcomes are stored only
  for member devices in the transaction that adds them, so a lower id predates
  the leave and a higher one is a real re-add: the floor is exact.
- A Welcome for this device at or below its conversation's floor is skipped:
  the cursor moves past it, nothing joins, its key package is still owed a
  replacement. Floors at or below the committed cursor are dropped lazily, on
  the next write of the floors.
- Only for a server that returns no `event_id` (an older one) the app reads
  the server's `latest_event_id` (an empty `GET /api/v1/sync/events` page) as
  the floor. That is not exact: a Welcome created between the leave and that
  read would also be skipped (a window of one request). If that read fails,
  the newest event id the running pass of the same session has fetched stands
  in (a pass of another session is ignored); it covers the page the pass holds,
  not events it has yet to fetch or a fetch still in flight.
- Server contracts, pinned by
  `server/internal/httpapi/sync_latest_bound_test.go`: the leave response's
  `event_id` equals the leaver's `membership.left` event id; a sync page
  requested past every event id is a 200 with no events, its `latest_event_id`
  is at or above that event although the left conversation no longer counts
  for the account, and the request changes what the device is served.
- Tests: `d70_s4_wiring_test.dart` covers a leave racing a pass that holds the
  older Welcome (no group kept, a later re-add joins, the key package is still
  owed); a re-add above the leave id but at or below `latest_event_id` joins;
  the leave id stands alone when the bound read fails; the fallback for a
  server with no `event_id`; the generation rule for the pass's fetched page;
  another conversation's Welcome is not skipped; the floor survives a restart.
  `api_bounded_decoding.dart` covers reading `event_id` (fixture
  `member_removed`) and an absent or unusable one as none.

## Not measured

The design asked for bytes and ms sealed per message, activation time and peak
RSS at 1, 100 and 1,000 groups of 100 members, against format 3. No such
measurement is in the repository, so none is claimed. Real-device and Linux demo end-to-end runs from a v3 database are not recorded
here.
