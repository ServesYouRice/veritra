# T49C mobile state and render benchmarks

Card I49 (T49C). Host measurements with the Flutter test framework, three
fixes for clear measured misses, and the misses left open. **No device or
emulator was available: runs on representative low-end Android and iOS
devices wait for G24.**

- **Host:** 4 vCPU Intel Xeon @ 2.70GHz, 15 GiB RAM, Linux 6.18 x86_64,
  shared with five other jobs (load average 5-10 during the runs).
- **Toolchain:** Flutter 3.44.0 stable (framework 559ffa3f75), Dart 3.12.0.
- **Mode:** `flutter test`: JIT code with debug asserts, a fake clock, layout
  and paint but no GPU rasterisation. Absolute times are not device times;
  compare rows with each other. Counts are exact.
- **Commits:** measurements `c173663`; fixes `3f3a4e2` (on `89a437e`).
- **Command:** `cd mobile && flutter test -j 1 test/perf/` (about 25 s after
  the fixes, 45-55 s before), then `grep 'T49C |'`. The full-cache burst:
  `VERITRA_PERF_FULL=1 flutter test -j 1 test/perf/startup_sync_perf_test.dart --plain-name burst`.
  "Before" ran the same tests against `c173663`'s `lib/`. Values are the
  median of three runs; the host was noisy, so treat differences under about
  1.5x in frame times as noise.

## What is measured

Tests live in `mobile/test/perf/` and stay in the normal `flutter test` run;
they assert counts and outcomes, never wall-clock thresholds.

- `startup_sync_perf_test.dart` uses the real encrypted database
  (`SecureLocalStore`, SQLite3MultipleCiphers in its background isolate).
- `render_perf_test.dart` uses `MemoryLocalStore` and the real app root
  (`VeritraApp` from `main.dart`, unmodified) at 360x800, pixel ratio 1.
- Crypto is a stand-in (`BenchMlsCrypto`) that commits the same transition
  as `NativeCryptoService` (envelope, decrypted text, state, cursor) without
  OpenMLS, so real decryption time comes on top of the burst numbers. This is
  the demo-build path; release builds keep crypto unavailable and never get
  this far.

**Datasets.** Device database: 500 conversations, 20 cached envelopes each
(10,180 rows), and 2,000 decrypted messages in one group (every tenth a
reply, every sixth with a reaction). Burst: 500 new messages into that
group, sync pages of 200; by default on a 50-conversation cache (1,180
rows, see miss 2), with `VERITRA_PERF_FULL=1` on the full cache. Render:
1,000 conversations for the chat list; a 2,000-message group (newest 50
from the server, the rest from local history) for the chat; per-bubble
runs at 20 conversations / 8 senders and 2,000 / 500 with the open
conversation last in the list.

## Results

| Scenario | Dataset | Before | After |
|---|---|---|---|
| Sync burst, total | 500 msgs, 1,180 cached | 14.7 s (29.5 ms/msg) | **3.8 s (7.6 ms/msg)** |
| Sync burst, total | 500 msgs, 10,180 cached | 22.5 s (45 ms/msg) | **13.2 s (26 ms/msg)** |
| Burst: history reloads / notifications | 500 msgs | 500 / 1,000 | **10 / 11** |
| One history reload | 2,000 msgs | 13-24 ms | same |
| Online restore (includes a snapshot rewrite) | 10,180 cached | 2.18 s | **0.47 s** |
| Open conversation (`loadMessages`) | 10,180 cached | 1.72 s | **0.29 s** |
| One snapshot rewrite | 10,180 cached | 1.65 s | **0.34 s** |
| Theme pair built + compared per root rebuild | - | 86 us + 21 us | **0 + 1 us** (shared) |
| Cold start, first ever (JIT): restore + first frame | 10,180 cached, offline | 358 + 335 ms | 330 + 318 ms |
| Cold start, warm code: restore + first frame | same | 179 + 134 ms | 159 + 109 ms |
| Chat-list scroll, 60 frames of 120 px | 1,000 conversations | median 14.1 ms, p90 21.5 | 13.2, 22.0 |
| Chat scroll, 60 frames of 120 px | 2,000 messages | median 8.4 ms | 8.2 ms |
| Chat scroll, 40 frames of 400 px | 20 conv / 8 senders | median 13.4 ms | 12.0 ms |
| Chat scroll, 40 frames of 400 px | 2,000 conv / 500 senders | median 13.1 ms | 11.6 ms |
| `timelineFor` per chat build | 2,000 messages | 0.4-0.6 ms | same |
| One AppState notification, chat list open | - | 52 ms, 854 elements | 31 ms, 854 |
| One AppState notification, chat open | - | 67 ms, 1,233 elements | 58 ms, 1,233 |
| Same, test-only scoped root (what-if) | - | 51 ms, 1,074 elements | 44 ms, 1,074 |
| One new message via sync, chat open | - | 3 frames, 1,233 elements | same |
| Tab switch, first frame | 1,000 conversations | 59 ms | 53 ms |
| Tab switch, state kept | - | selection yes; list offset no; wide draft no | same |
| Commit one received message (store only) | 10,180 vs 0 cached envelopes | 25.7 vs 5.4 ms | 26.4 vs 4.6 ms |
| Reload history of an empty conversation | 2,000 rows elsewhere | 0.6-1.0 ms | same |

Rebuild counts per notification with a chat open: 1 `MaterialApp`, 1
`AppShell`, the hidden chat list (1 `ChatListScreen`, 15 rows), 1
`ChatScreen` and its 6 visible bubbles. The chat list scroll built 112 rows
in 60 frames; the chat scroll 37 bubbles.

## Fixes (commit `3f3a4e2`)

1. **Sync burst was quadratic.** `_runOwnedCatchUp` merged each received
   envelope and reread the conversation's whole decrypted history
   (`refreshHistory`) after every message, then notified twice. It now
   collects received envelopes and publishes them with one history read per
   conversation at most every 50 messages and at the end of each page.
   *Invariants:* every event still commits atomically before the next one is
   applied (unchanged); history is read before envelopes are merged, so no
   frame shows a decrypted message as an undecryptable bar; nothing is
   applied once the sync owner (session generation) changed; messages
   committed before a mid-page failure are still shown (new test in
   `sync_recovery_test.dart`). Single realtime messages are still shown as
   soon as their page ends. *Rollback:* revert; no data change.
2. **Snapshot rewrite took seconds.** `replaceSnapshot` inserted every cached
   conversation and envelope with its own round trip to the database isolate.
   It now inserts them in one batch inside the same transaction. Same rows,
   order and transaction; a failing rewrite still rolls back completely (new
   test in `encrypted_local_store_test.dart`). No schema change.
3. **Themes rebuilt on every root rebuild.** `veritraLightTheme()` and
   `veritraDarkTheme()` built a new `ThemeData` per call, and the root calls
   both on every AppState change. They are now built once. Values are
   unchanged (goldens pass under `TZ=UTC`). Equal themes never animated or
   notified dependents, so the saving is only the build and the deep
   comparison.

Checks: `flutter analyze` clean; `VERITRA_CRYPTO_LIBRARY=... flutter test
--coverage` 328 passed, 2 skipped (live contract server, demo e2e);
coverage 60.53% (floor 43%); goldens pass with `TZ=UTC`.

## Measured misses left open (recommendations)

1. **Whole-app rebuild per AppState notification.** `VeritraApp` in
   `main.dart` wraps `MaterialApp` in the AppState listener, so every
   notification rebuilds the Navigator and every route's page, including the
   chat list hidden under an open chat (15 rows each time). A test-only root
   that listens only to the appearance controller and lets `AppShell` listen
   itself (`scopedRootApp` in `perf_harness.dart`) rebuilt 1,074 instead of
   1,233 elements, with frames 13-30% shorter in most of ten paired runs. Not done: `main.dart` is a
   release-gate file, and pushed routes other than `ChatScreen` may rely on
   the cascade for updates, so each needs an audit first. A further step is
   to stop rebuilding the hidden list. *Fixed (T49C-1), both steps: see
   "After: scoped listeners and kept tab state" below.*
2. **Every received message's commit scans the ciphertext cache.**
   `commitMlsTransition` finds the next envelope position with `WHERE
   conversation_id = ? ORDER BY position DESC LIMIT 1` on
   `local_ciphertext_envelopes`, which has no index but the primary key:
   26 ms against 5 ms per message at 10k cached rows. It dominates the
   full-cache burst. Proposal: an additive Drift migration (schema 9) adding
   an index on `(conversation_id, position)`, which also serves the ordered
   snapshot read at startup. Target: per-message commit within 1 ms of the
   empty-cache cost at 10k rows. Rollback: older code ignores the index.
   Needs the migration advisor checkpoint, so not done.
3. **The whole snapshot is rewritten on every online restore, conversation
   refresh, conversation open and older page.** Now about 0.3 s at 10k rows
   instead of 1.7 s, but still proportional to the cache (with
   `secure_delete` on). Incremental per-conversation writes would change the
   storage design; needs review.
4. **Tab state.** Returning to Chats resets the list scroll offset; in the
   wide layout, switching destinations drops an unsent composer draft and
   reply target. Selection is kept. Keeping scroll offsets (page storage) or
   drafts (held outside the chat widget) is a product decision; the draft
   loss loses user text. *Fixed (T49C-4), all three kept: see below.*
5. **No action:** per-bubble linear lookups (DM check over the conversation
   list, sender name over the roster) and `timelineFor`'s merge and sort per
   chat build showed no measurable effect at 2,000 conversations and 500
   senders.
6. **Not measured here:** device frame times, memory and cold start on
   low-end Android and iOS (G24); OpenMLS decryption inside the burst; the
   legacy repair path that fetches one envelope per event without an inline
   copy.

## After: envelope index

Measured miss 2, fixed: local schema 9 adds the index
`local_ciphertext_envelopes_conversation_position` on
`(conversation_id, position)` (index only, `CREATE INDEX IF NOT EXISTS`; see
`docs/crypto.md`). `EXPLAIN QUERY PLAN` for the tail lookup went from `SCAN`
plus `USE TEMP B-TREE FOR ORDER BY` to `SEARCH ... USING INDEX
(conversation_id=?)`; the ordered snapshot read now walks the index instead
of sorting. Same host and commands as above, 2026-10-23, load average 0.4-2.6.
Medians of three runs; "before" is `d2d9eb8`'s `lib/`, run the same day.

| Scenario | Dataset | Before | After |
|---|---|---|---|
| Commit one received message (store only) | 10,180 vs 0 cached envelopes | 23.4 vs 5.6 ms | **5.4 vs 5.4 ms** |
| Sync burst, total | 500 msgs, 10,180 cached | 13.1 s (26 ms/msg) | **2.6 s (5.2 ms/msg)** |
| Sync burst, total | 500 msgs, 1,180 cached | 2.7 s (5.3 ms/msg) | 2.4 s (4.9 ms/msg) |
| One snapshot rewrite | 10,180 cached | 265 ms | 313 ms |
| Online restore / open conversation | 10,180 cached | 435 / 319 ms | 431 / 313 ms |
| Cold start restore, first / warm code | 10,180 cached | 308 / 182 ms | 269 / 165 ms |

The target is met: at 10k rows a commit costs the same as with an empty
cache. The snapshot rewrite now also maintains the index (+48 ms median,
within this host's noise). Rollback: revert. A schema 8 build that opens a
v9 file records version 8 and keeps using the index; this was checked with the
schema 8 code.

**Migration advice (advisor checkpoint).** Verdict: sound for demo builds,
no must-change. Adopted: every upgrade step and `PRAGMA user_version` run in
one transaction (a test forces a v7 upgrade to fail at the index and finds
version 7 with no v8 columns; the next open completes it); a comment that
`PRAGMA foreign_keys` is ignored inside that transaction; a non-unique index;
the rewrite cost measured above. Downgrade is acceptable as long as no other
branch claims schema 9 for a different change. Follow-ups, not schema
changes and not done here:
- A failed upgrade, for example when the disk is full, surfaces as
  `keyRejected`. The file and its key are kept, and quarantine needs
  confirmation and keeps a readable copy, but the message is wrong. It needs
  its own failure kind and string.
- Android 12+ device-to-device transfer ignores `allowBackup="false"` unless
  `dataExtractionRules` excludes the file, and iOS backups include it. A
  copied file cannot be opened without its device-only key, so it lands on
  the recovery screen.

The app's own encrypted backup is a logical export, so this change does not
affect it.

## After: scoped listeners and kept tab state

Measured misses 1 (T49C-1, commit `78faf94`) and 4 (T49C-4, commit
`9aa7153`), fixed. Same host and command as above (`flutter test -j 1 test/perf/render_perf_test.dart`), 2026-10-23,
load average 1.0-3.6, medians of three runs. "Before" is `138891c`'s `lib/`,
run the same day. Both ran with `pubspec.yaml`/`pubspec.lock` from
`6d188b1^`: the intl 0.20.3 bump in `6d188b1` does not resolve with Flutter
3.44.0 (`flutter_localizations` pins intl 0.20.2).

**What changed (T49C-1).** The root in `main.dart` listens only to the
appearance controller; the lines that pick the crypto service are untouched.
Each part of the UI listens for what it draws, through
`ListenableSelector` (`lib/ui/widgets/listenable_selector.dart`, no new
dependency): it reads a selection after every notification and rebuilds only
when the selection changed. `AppShell` selects the lifecycle and whether a
session exists; the wide layout's detail pane the selected conversation; the
connection banner what it draws; the chat list its conversations, loaded
flag, account, selection and mute flags; the open chat everything its build
reads for that conversation (its envelopes, decrypted history, roster,
pending sends and their states, busy and error flags). AppState replaces its
lists instead of editing them, so lists compare by identity. Screens that
relied on the root rebuilding every route now listen themselves
(`ConnectScreen`, `CommunityScreen`, `SearchScreen`, `ProfileScreen`, the
recovery screen); the others already did, and no sheet or dialog reads the
state in its build except through its own listener. The what-if root
(`scopedRootApp`) is gone from the harness.

| Scenario | Dataset | Before | After |
|---|---|---|---|
| One AppState notification, chat list open | 200 conversations | 21.6 ms, 854 elements | **0.05 ms, 0 elements** |
| One AppState notification, chat open | 2,000 messages | 34.1 ms, 1,233 elements | **0.05 ms, 0 elements** |
| One new message via sync, chat list open | same | 2 frames, 31.5 ms, 854 elements | **1 frame, 5.2 ms, 0 elements** |
| One new message via sync, chat open | same | 3 frames, 52.8 ms, 1,233 elements | **3 frames, 37.7 ms, 352 elements** |
| Tab switch, first frame (list at 3,000 px) | 1,000 conversations | median 36.0 ms, p90 64.2 | 43.2 ms, p90 152 |
| Tab switch, state kept | - | selection yes; list offset no; wide draft no | **selection, list offset, draft and reply target** |
| Chat-list scroll / chat scroll | 1,000 conv / 2,000 msgs | 4,039 / 1,293 elements | same |

With a chat open, a new message in it now rebuilds the chat (1 message list,
1 composer, 6 bubbles) and nothing else: not `MaterialApp`, the shell or the
15 rows of the list hidden under it. A notification that changes nothing
visible rebuilds nothing. The chat list did not change for a message in this
benchmark, because new messages do not change the conversation list until it
is refreshed.

**Regression test.** `test/scoped_rebuild_test.dart` opens a chat through its
row, in the phone layout (pushed route) and the wide layout (detail pane),
and fails if a bare notification, a device-list refresh, going offline or a
message synced into another conversation rebuilds `MaterialApp`,
`ChatScreen`, the message list, a bubble or the composer. It also checks
that a message in the open conversation still reaches the screen and that
the shell still follows the session lifecycle. Checked against both ways it
could regress: with the old root listener it fails on `MaterialApp`, with a
chat that rebuilds on every notification it fails on the message list.

**Tab state (T49C-4).** The chat list's `ListView` has a `PageStorageKey`
(per account), so its offset survives another destination replacing it, in
every layout. Unsent text and the reply target are held per conversation in
`AppState.composerDrafts` (`lib/core/composer_drafts.dart`), which outlives
the chat widget: switching destinations, switching conversations in the wide
layout, or leaving a pushed chat and opening it again keeps them. Drafts are
memory only: never written to the local database or the outbox, never sent,
never logged (`toString` prints counts), and cleared when the session ends
(`_clearLocalSession` and the restore-failure path) or the conversation is
left. A send that was accepted clears its draft even if the chat closed
meanwhile, so sent text never returns as a draft. Tests:
`test/tab_state_test.dart` (wide layout: list offset, draft, reply target,
per-conversation drafts, nothing stored or sent, sign-out clears).

*Cost:* returning to a list scrolled 3,000 px lays out the rows above the
offset once (about 45 rows; the list has no fixed row extent), which is the
p90 rise in the tab-switch row. The median is within this host's noise, and
the cost is proportional to the offset, paid only on the return frame.
*Rollback:* revert; no data or schema change.
