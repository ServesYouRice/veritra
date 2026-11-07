# B3 polls — 2026-11-07

Status: implemented on the W7 payload v2 design; checked by CI only (no
Flutter or Dart in the authoring environment). No counter bumped: ABI 12,
local schema 18, migration 0046 unchanged. No server change.

## What works

- Composer: a poll button opens a dialog (question, 2-12 options, "allow
  several answers"). It sends a `poll` payload (v2, not hidden).
- Voting: tap an option to vote, tap again to take it back; tapping another
  option on a single-choice poll replaces the vote. Each change sends a
  `poll_vote` payload (v2, `hidden: true`, so an older app stores it unseen).
- Tallies: per-option count and bar, total voters. Only accounts in the
  current roster count. The bubble says everyone can see who voted for what;
  there is no anonymous mode.
- Strings: English and Serbian Cyrillic in the ARB files; the Latin ARB came
  from `scripts/l10n-sr-latn.py` (its `--check` passes). The generated
  `app_localizations*.dart` were extended by hand to match.

## Design notes and deviations

- Votes are kept in the poll row's `body` JSON, not in the reserved
  `local_poll_votes` / `local_poll_state` tables, because those need a schema
  bump. Delete and delete for me clear the body, so votes go with the poll;
  backup carries them with the message.
- Wire names are `poll` and `poll_vote` (explicit `wireName`; existing
  strings unchanged).
- `poll_close` is not turned on (not in this brief); it remains `unsupported`.
- Own vote is applied when sent. Same account on two devices can briefly
  disagree about the last vote (documented in `docs/crypto.md` 5.5).
- Polls are skipped by the K2 history snapshot (its reader rejects unknown
  kinds), so a new device does not copy them.
- Existing tests that used `poll` as an example of an unsupported type now use
  `admin_delete`.

## Checks

- Added `mobile/test/b3_polls_test.dart`: codec (vectors 11-13, v1, limits,
  wire name, hidden flag), pure poll rules, effect building, and both stores
  (memory and SQLite): vote, change, retract, invalid/wrong-target votes,
  delete, delete for me, backup restore.
- Not run locally: `flutter analyze`, `flutter test` (not installed). GitHub CI
  on the PR is the check.
