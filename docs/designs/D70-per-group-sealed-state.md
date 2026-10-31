# D70: per-group, incremental sealed MLS state

Status: proposed (Opus, 2026-10-31). Changes the sealed-state format, the
crypto ABI (9 → 10) and the local schema; every package below gets an Opus
review. The `docs/crypto.md` change-log entry lands with the ABI-10 package.

## Problem

`seal_state` (`crypto/rust/src/mls/state.rs`) puts the whole `MemoryStorage`
map, the signer and the K2 transfers into one AES-256-GCM blob (format 3).
Hard caps: 100,000 records, 4 MiB per record, 32 MiB in total (also in
`ffi.rs` `MAX_STATE_BYTES` and on restore). Nothing shrinks the state: no
leave or delete call, unclaimed key packages are never pruned, and
`MlsGroup::delete` leaves past-epoch key pairs. (This design first assumed
`clear_pending_commit` leaks the staged update-path key pair. S1 showed
that is wrong for OpenMLS 0.9.2: a commit's path keys live inside the
staged commit, in the group state record. Standalone key pairs come only
from update proposals, which Veritra does not make.) Once a cap is hit every `_sealNext` fails, sync
stops under I33 and the device stays on the recovery screen. Every event
also re-encrypts all state, which is unworkable at C8 group sizes.

**Goals.** Seal only what an operation changed. No cap can be reached just
by accumulating state: every growing set has a pruning path. Keep today's
guarantees: a stale or mismatched state is refused, and state, cursor and
effects commit in one SQLite transaction. Migration from format 2/3 is
one-way and crash-safe.

**Non-goal.** On-demand group loading. Activation still loads every record
into memory, as today; the manifest keeps it open as a seam left switched
off.

**Threat model (unchanged).** The state key and counter live in the same
SQLite3MC database as the blobs. The binding gives consistency (no records
mixed from different snapshots) and stale-backup refusal. It does not stop
someone who can write the database: they already hold the key.

## 1. Native storage: a partitioned provider

`MlsDevice.provider` becomes `VeritraProvider { crypto: RustCrypto,
storage: PartitionedStorage }`, implementing `OpenMlsProvider`. Both types
are re-exported by `openmls_rust_crypto`, so no new crate.
`PartitionedStorage` implements `StorageProvider<CURRENT_VERSION>` (53
methods in OpenMLS 0.9.2 without draft features). Each method delegates to one inner `MemoryStorage`:

| Partition | Gets |
|---|---|
| `device` | `SignatureKeyPair`; PSK methods (unused today) |
| `group(id)` | every method that takes a `GroupId`: tree, context, secrets, epoch key pairs, proposals, own leaf nodes, join config, group state, resumption PSKs |
| `group(scope)` | `write/read/delete_encryption_key_pair` (standalone key pairs, which carry no group id; only update proposals write them) |
| `kp(hash_ref)` | `write/read/delete_key_package` |

- **Scope guard.** Every `MlsDevice` group method sets the active group
  before calling OpenMLS. A group-keyed call for another id fails with
  `MlsError::Storage`, and so does a key-pair write with no scope. A record
  can never be filed under the wrong owner without an error.
- **Group id bytes.** Routing uses the exact key bytes `MemoryStorage`
  writes for a `GroupId` (S1 takes them from a probe `MemoryStorage`) (O3).
  A key package's hash reference is serialized once with `serde_json`
  (D76), so a lookup goes straight to its partition: a Welcome may name
  thousands of references.
- **Byte-identical keys.** Inner keys and values are exactly what
  `MemoryStorage` writes today. The partitions together equal today's flat
  map.
- **Dirty tracking.** Writes and deletes mark their partition dirty. The
  device record (signer plus `pending_transfers`) is compared by a digest of
  its encoding at seal time, so no transfer change is missed.

**Pruning in the core:**

- **No commit-key pruning.** In OpenMLS 0.9.2 `clear_pending_commit`
  leaves no standalone pair (S1 tests this), so nothing is pruned there. A
  withdrawn update proposal does leave its pair; it sits in that group's
  partition and goes with it.
- **Own removal.** When a processed commit leaves the group inactive (own
  removal applied), the whole group partition is dropped in the same
  operation. That also clears the past-epoch pairs `MlsGroup::delete` misses.
- **`group_delete(id)`.** Drops a partition; called only on a user action
  (leave or delete a chat), never on a server's word. Otherwise a server
  could clear an active group and plant a forked Welcome, which "Rejoining a
  conversation" forbids. With an inactive group pruned, a re-add is a fresh
  join; the "active group never replaced" check is unchanged. The note goes
  into `docs/crypto.md`.
- **Key packages.** `prune_key_packages(now)`, called after a caught-up
  sync pass, drops `kp` partitions whose `not_after` (84 days by default;
  the server hands a package out for at most 30) passed over 24 h ago. This
  bounds unclaimed packages, never-accepted batches (`app_state.dart`) and
  claims burned under D64. To confirm in S1: if OpenMLS checks leaf
  lifetimes on join (`LeafNodeLifetimePolicy::Verify`), a Welcome after
  `not_after` already fails today and pruning adds no failure.

## 2. Format 4: records

Each record is `header || u32 len || AES-256-GCM(state_key, nonce,
plaintext, aad = header)`:

```
header = "PMMLSST1" || u16 version=4 || u8 kind || u64 generation
         || u16 len account_id || u16 len device_id || u16 len record_id || nonce12
kind   = 0 root | 1 device | 2 group (record_id = raw group id) | 3 kp (record_id = hash_ref)
```

- The magic stays, so an ABI-9 build reads version 4 as `UnsupportedFormat`:
  a downgrade fails closed toward re-linking.
- Device, group and kp plaintext is today's sorted `encode_records` map; the
  device record adds today's `transfer::encode` section.
- **Root plaintext** is the manifest: `signer_public_key || u32 n || n ×
  (kind, record_id, generation, SHA-256(sealed record))`, sorted. An entry
  listed but not loaded is the on-demand seam.
- **Nonces** are random under one key; 2 to 3 seals per transaction keeps
  2^32 seals centuries away at one transaction a second. Key rotation is a
  later seam.

**One counter: the generation.** It is the existing
`LocalCryptoStates.counter`.

- Each transaction reseals the root at `previous + 1`. Changed records carry
  that generation; unchanged ones keep the generation and digest the root
  lists.
- So every Dart `expectedCounter` check, `counter == expected + 1`,
  `_deviceCounter` and the backup comparison stays as it is.
- **Restore requires:** the root generation equals the stored counter and is
  at least the minimum; every listed record is present exactly once with
  matching kind, id, generation and digest; no extra records; identity in
  every header. Any failure is `InvalidState`. A stale record fails on its
  digest; a missing group fails closed instead of reading as "not a member".
- **Seal order.** `seal_changes(g)` needs `g == last_sealed + 1`; restore
  resets `last_sealed`. An uncommitted change set must be followed by
  `_restorePrevious` (today's invariant, also caught by `_requiredState`).

**Caps.** Per record, checked on seal and restore, set well above admission
limits:

| Record | Cap |
|---|---|
| root | 16 MiB, 200,000 entries (D38 allows 1,000 conversations by default) |
| device | 1 MiB (16 transfers × 12 KiB, plus the signer) |
| group | 32 MiB (today's whole-state cap, so any group that fit still fits), 4 MiB per value, 10,000 values |
| kp | 256 KiB; pool of at most 1,000 |

- Caps bite at admission where possible: `create_key_package` refuses a full
  pool, and replenishment retries without blocking sync.
- A seal-time overflow returns new `PM_CRYPTO_RECORD_LIMIT` (-8) and writes
  the offending kind and id to `out`. Nothing is sealed and the dirty set is
  kept, so the app can name the chat and offer to leave it instead of
  re-linking.
- C8 measures group-record size at each member step (`testing/evidence/`)
  and keeps it at most a quarter of the group cap.

## 3. ABI 10 (`veritra_crypto.h`, `ffi.rs`, Dart bindings)

| Call | Purpose |
|---|---|
| `pm_crypto_device_seal_changes(h, key, generation, out)` | Change set: root, then `(op upsert/delete, kind, id, sealed)` frames. Replaces `pm_crypto_device_seal_state`. Per-record caps only, no total |
| `pm_crypto_restore_begin(acct, dev, key, min_gen, root, out_loader)` | Opens and checks the root |
| `pm_crypto_restore_add(loader, sealed_record)` | Checks one record against the manifest |
| `pm_crypto_restore_finish(loader, out_handle, out_gen)` / `pm_crypto_restore_abort(loader)` | Fails unless every entry was added; frees the loader exactly once |
| `pm_crypto_device_migrate_v3(acct, dev, key, counter, blob, out_handle)` | Format 2/3 only; classifies into partitions, all dirty |
| `pm_crypto_group_delete(h, group_id)` | Drops a partition (user action only) |
| `pm_crypto_device_prune_key_packages(h, now_unix_s, out_removed)` | Expiry pruning |

- `pm_crypto_device_restore` and `_seal_state` are removed. The loader is
  its own opaque type (use after finish or abort is `INVALID_ARGUMENT`).
  Dart pins the ABI exactly, so Rust ABI 10 and Dart land in one PR.
- **Errors after a delete.** An operation on a deleted group must map to the
  same Dart error kind as one on an inactive group today: `groupEpoch` still
  reads "missing group" (D54), and a late application message still becomes
  a placeholder, not an I33 stop. S3 tests this.

## 4. Local storage (next free schema version; K2 has claimed 16)

- **New table** `local_crypto_records(kind INT, record_id BLOB,
  generation INT, sealed BLOB, PK(kind, record_id))`.
- **`LocalCryptoStates`** keeps `counter` and `stateKey`; `sealedState`
  holds the root, or the v3 blob until migration.
- **`StoredCryptoState`** gains `changes` (upserts and deletes).
  `writeCryptoState`, `commitMlsTransition`, `commitOutgoingMlsTransition`,
  the revocation transition and `commitLocalMlsState` apply them in the same
  transaction, after the existing counter and cursor checks and before the
  singleton write.
- **Loads.** `loadCryptoState` returns counter, key and root (cheaper than
  today's full blob). `loadCryptoRecords` streams rows for restore.
- **Every path that deletes or replaces the singleton** clears the records in
  the same transaction: identity reset (~831), `importLegacy` (~878), backup
  restore (~1051), `clearAll` (~2007), and the in-memory `LocalStore`.
- **Backup export** reads root and records in one read transaction.

Dart service (`native_crypto_service.dart`): `_sealNext` calls
`sealChanges(key, previous.counter + 1)`; `_restoreDevice` runs begin, add
over `loadCryptoRecords()`, finish. Activation, `_requiredState`,
`_restorePrevious` and the D54 retry keep their logic and gain no counters.

## 5. Migration from format 2/3 (one-way, crash-safe, fail-closed)

**Trigger:** the singleton holds a format 2/3 blob and the records table is
empty, whatever put it there (upgrade, old backup, legacy import). The
version bytes only choose the route; Rust re-verifies everything.

1. `migrate_v3` runs today's full checks: AEAD, identity,
   `counter == stored`.
2. **Classify** each flat key by its exact `MemoryStorage` label, then parse
   the JSON `GroupId` or hash ref and require the trailing `u16` version.
   - Standalone `EncryptionKeyPair`s come only from update proposals. Each
     goes to the group whose `OwnLeafNodes` hold a leaf with that
     encryption key. The rest are past leaks: dropped and counted. (S1
     keeps them in an unowned store so v3 re-seals byte-identically.)
   - Inactive groups are dropped.
   - An unknown label, unparseable key or duplicate fails with
     `InvalidState`.
3. **Self-check:** partitions plus dropped keys equal the input map, and
   every group loads at the same epoch from both providers.
4. `seal_changes(counter + 1)` emits every record.
5. **Commit:** Dart's `commitCryptoMigration` is one compare-and-swap
   transaction. It requires counter == N, a stored blob byte-equal to the v3
   blob it read, and an empty records table; then it writes all records and
   the root at N + 1.

A crash before the commit leaves v3 intact and migration reruns; after it,
a downgraded build reports `UnsupportedFormat`; a failed migration leaves v3
untouched on today's recovery screen.

## 6. Backups (depends on O1)

- **If D71 drops the MLS state and key from backups** (recommended, matching
  K0's "restore makes a new device"): no crypto state in backups, and no
  change to VBK2 or the backup JSON from D70.
- **Otherwise:** backup plaintext v6 carries `{counter, state_key, root,
  records[]}` from one read transaction, restored atomically with today's
  "not older than local" check. The 64 MiB backup plaintext cap then becomes
  the effective total state cap, stated in `docs/crypto.md`.
- Either way, a v5 backup restored after the upgrade puts a v3 blob in the
  singleton, and section 5 migrates it.

## 7. Tests

Rust (`state.rs`, new `mls/storage.rs`, `ffi.rs`, `tests/`):

- **Routing:** each operation dirties only its own partitions (a group op
  its group; key-package creation its `kp`; join its `kp` and group);
  out-of-scope or wrong-id writes error.
- **Refusal:** restore refuses an old-generation, foreign, missing or extra
  record, a wrong key or identity, a root below minimum (`Rollback`), and
  versions 0, 1, 5, `u16::MAX` (`UnsupportedFormat`); a second seal without
  a restore is refused.
- **Pruning and caps:** clear leaves no standalone pair; own removal and
  `group_delete` drop the partition; expiry keeps live packages; a full pool
  is refused; an oversized group returns -8 with its id, dirty set kept.
- **Migration:** a genuine v3 fixture from the current build (two or more
  groups, a staged commit, an inactive group, unclaimed key packages, a K2
  transfer) plus the v2 fixture. The union equals input minus counted drops,
  the staged commit merges, a peer interoperates both ways, an unknown label
  fails closed, the v3 reader refuses a v4 root.
- **Property test:** random operations over 3 devices and 5 groups with
  random restarts from a simulated table, compared with a twin that never
  restarts (epochs, decrypts, safety numbers).

Dart (`mobile/test/`): changes apply atomically (failure injector at
`afterValidation`/`afterState`; a stale `expectedCounter` writes nothing);
every singleton-clearing path clears records; migration reruns after a crash
and refuses a second run or a changed blob; `_restorePrevious` and the D54
retry work with records; backups round-trip under O1; the Linux demo e2e
starts from a v3 database fixture.

**Evidence** (`testing/evidence/D70-sealed-state.md`): bytes and ms sealed
per message, activation time and peak RSS at 1, 100 and 1,000 groups of 100
members, against v3.

## 8. Packages, in order

1. **S1, Rust internal (Opus review).** `VeritraProvider`,
   `PartitionedStorage`, scope guard, own-removal pruning, v3 classifier
   (no commit-key leak to prune; see section 1). No ABI or format change: `seal_state` still writes v3 as the
   union of partitions, and v3 restore runs the classifier, so it is
   exercised on every restore before anything depends on it.
2. **S2, local schema (Opus review).** Table, `changes` plumbing,
   singleton-clear coverage, in-memory store. Inert until S3 (`changes`
   always empty).
3. **S3, ABI 10 with Dart bindings and service, one PR (Opus review).**
   Format 4, change-set seal, loader restore, `migrate_v3`, `group_delete`,
   key-package pruning, -8, migration commit; the `docs/crypto.md` change
   log and "Rejoining" note; `veritra_crypto.h` comments.
4. **S4, wiring (Sonnet, Opus review).** Prune key packages after a
   caught-up sync; a "this chat is too large" screen for -8 that offers to
   leave; C1's leave calls `group_delete` when C1 lands.
5. **S5, backups (after O1):** drop `crypto_state`, or backup v6.
6. **Evidence and STATE.md:** mark D70 built.

**Ordering risk with K2.** K2's remaining work targets ABI 9 and local
schema 16. Land S3 before K2's ABI-dependent work or rebase onto it, so the
two never both claim ABI 10 or the same schema number.

## 9. Choices and what would flip them

| Chosen | Alternative wins if |
|---|---|
| Manifest root resealed per transaction | Root resealing measures badly at C8 scale (about 60 KB per transaction at 1,000 groups, expected negligible). Per-row counters alone lose "a missing or stale record fails closed" |
| Load all records at activation | Peak RSS or activation time at 1,000 groups is too high, or `_restorePrevious` reloads hurt D54 retries: switch on on-demand loading (the manifest allows it) |
| One record per key package | Per-row overhead matters more than O(1) pruning and joins |
| Dirty set cleared at seal, guarded by the generation rule | Some Dart path keeps a handle after a failed commit (none does: `_requiredState` restores); then add an acknowledgement call |

## Owner decisions

- **O1. Does D71 also drop the sealed MLS state and its key from backups?**
  Recommended yes (K0): D70 then needs no backup format change. If no,
  backup v6 carries the records and 64 MiB becomes the effective state cap.
- **O2. A Welcome this device cannot open because its key package expired
  or was pruned** (can already happen after 84 days today). Recommended:
  skip it with an "ask to be re-added" notice, since refusing a Welcome
  forks nothing. Alternative: keep I33's sync stop. Either way it settles
  I33's scope for Welcomes, so it is the owner's call.
- **O3. Declare `serde_json` as a direct, exactly pinned dependency.** It is
  already locked and compiled in through `openmls_memory_storage`
  (MIT/Apache-2.0); add a `THIRD_PARTY_NOTICES.md` row. Routing and
  migration need it.
