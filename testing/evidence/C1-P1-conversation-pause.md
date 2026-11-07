# C1 prerequisite 1: per-conversation MLS failure pause - 2026-11-07

Branch `agent/c1-p1`. Built as the hybrid in
[C1-sync-isolation](../../docs/designs/C1-sync-isolation.md), "Built slice
(P1)". Needs an Opus review (MLS ordering). Inert unless the operator sets
`PRIVATE_MESSENGER_SCOPED_SYNC`; the owner decides whether the demo or the
default turns it on.

## What was run here

- `dart format --language-version=3.4 --set-exit-if-changed lib test`
  with Dart SDK 3.12.2 (the Dart in Flutter 3.44.0), after confirming the
  untouched baseline of the repository formats clean with the same command.
  Result: 0 changed over 313 files.
- `go test ./internal/httpapi -run TestScopedSync` in `server/`: passes,
  including the new probe test (`after=<id-1>&limit=1` returns exactly the
  named event for owner and member, with hidden rows below it, and echoes
  `scope_id`).

## Left to GitHub CI (Flutter is not installed here)

`flutter pub get`, `flutter analyze` and `flutter test`, including the new
and changed tests:

| Test | What it shows |
|---|---|
| `test/c1_conversation_pause_store_test.dart` | The pause row, skip needs the row, replay behind the cursor does not move it, refusals (unpaused conversation, below `resume_after`, cursor-advancing for a paused group, outgoing), the 1,000 limit, clear with generation, cleared with the MLS state, the 18 to 20 upgrade. Database and memory store |
| `test/c1_native_pause_test.dart` | Real OpenMLS devices: group A paused and skipped, group B receives, sends and seals; A refuses outgoing work; restart keeps the pause; replay applies A's events in order behind the cursor; B's history and keys are intact; A works again after the pause is lifted. Runs only where the native library is built |
| `test/app_state_catch_up_test.dart` (new group) | Pause on failure and sync goes on, retry replays in order and lifts the pause, a retry that fails again keeps it, a stop recorded before pauses becomes the pause, route off keeps the device-wide stop, an event the server cannot serve again is never passed over |
| `test/chat_sync_paused_test.dart` | The chat notice offers retry and leave, only leave after the server pruned, nothing for another conversation |
| `test/sync_recovery_test.dart`, `test/app_state_catch_up_followups_test.dart` | Their fake API answers 404 for the new route, so their device-wide stops are unchanged |
| `test/k2_schema18_test.dart` | Expects the current schema number, not 18 |

## Review fixes (PR #137)

- B1: the replay ends only at an empty page or at an event above the global
  cursor. A short page is not the end: `ApiClient._shrinkingPage` halves a
  page over 16 MiB, and a server may send short pages. Tests in
  `app_state_catch_up_test.dart` serve the stream two events to a page: the
  replay applies every held event before the pause goes, and a failure on
  the third page keeps the pause at that event.
- B2: a failed event type over 128 characters is never stored. The table has
  a CHECK, `MemoryLocalStore` and `writeConversationPause` refuse it,
  `failurePausesConversation` and `_pauseConversationAt` decline the pause,
  and the device stops as before. Tests in
  `c1_conversation_pause_store_test.dart`.
- B3: `c1_native_pause_test.dart` has a second case on real OpenMLS devices.
  A damaged commit goes through `processMlsMessage` and fails (the handle is
  restored, counter, epoch and cursor unchanged). A is paused and skipped, B
  moves to a new epoch, then the replay merges A's real commit and decrypts
  the new-epoch message behind the cursor: the cursor and B's epoch do not
  move and the counter rises by one per transition.
- B4 (merge order, no code change here): schema 19 (C6, `from < 19`,
  `_createFrankReveals`) and schema 20 (this PR) must not land in the wrong
  order. Merge C6 first, or renumber C6 to 21. `_createFrankReveals` is
  idempotent (`CREATE TABLE`, `CREATE INDEX` and `CREATE TRIGGER` all use
  `IF NOT EXISTS`), so either is cheap. The coordinator chooses; the choice
  is not recorded here.

## Not covered

- Not run: `flutter analyze`, any Flutter test, the native test, the
  Rust tests (no Rust change), and `scripts/test` / `scripts/lint` as a whole.
- The design's native evidence (two groups under concurrent membership
  commits, crash injection at every atomic write stage, a flood of
  attacker traffic, fair scheduling) is not built. `c1_native_pause_test.dart`
  is the sequential two-group case only.
- A downgrade to a build before schema 20 was not tried.
- No measurement of cost with 1,000 paused conversations.
- Not checked on a device or against a running server with the switch on.
