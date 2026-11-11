# C3 review follow-up: retain key ordering

This is a tested slice, not completion of C3 or clearance of all review findings.

## Change

Memory and SQLite stores erase evicted key bytes but retain their original
identity and sequence as tombstones. Replayed keys cannot acquire a newer
sequence after eviction. Existing sender authorization and key selection rules
are preserved; selection still requires this account or a verified owner/admin.
This does not introduce a new authenticated generation protocol.

Key material remains bounded to four unprotected keys per sender, group and
subject, plus keys protecting accepted records. Tombstones contain no key bytes;
their metadata grows with distinct received key identities until local MLS
state is cleared. This tradeoff needs reconsideration with a future bounded,
authenticated key-generation protocol before C3 is declared complete.

## Regression coverage

- Memory and SQLite: eviction destroys bytes, retains sequence, and repeated
  delivery does not resurrect retired material.
- SQLite: close/reopen retains ordering and rejects resurrection.
- Native-backed service: seven rotations evict the retired key; a trusted stale
  admin replays it after a service restart; the next edit uses the current key.

## Decisions and limits

- Earlier `origin/agent/c3` is already an ancestor. `origin/agent/c3-2` sender
  work was already ported; inspected branch history and existing implementations.
- No schema, migration, ABI, dependency, STATE.md, CI or release-gate changes.
  Reserved local schema 35 and migration 0067 remain unused.
- Existing key history already deleted by older versions cannot be reconstructed.
  These tests establish protection for subsequent eviction, not recovery of
  previously lost ordering. Existing demos need fresh local state/community
  recreation; a preserving upgrade protocol remains unfinished.
- Production verified C4 role source/restriction flag, remote/moderator-removal
  rotation, immediate add-key delivery, conversion, category/icon screens,
  encrypted creation and plaintext-name refusal/column removal remain open.
- Worked alone, as requested. No external changes or push.

## Checks

Focused native-backed Flutter: 64 passed, no skips.
Go tests: passed. Cargo tests: 230 passed, 8 existing ignores.
Full lint: passed (Go vet, Rust fmt/clippy, Flutter analyze, Dart format).
Full `scripts/test.ps1`: exit 0, including 2,446 Flutter tests and 21 existing skips.
`git diff --check`: passed. An initial PowerShell capture reported normal stderr
as errors; reran with external redirection to verify the script exit status.
Raw logs are retained alongside this file as `c3-revision-*.log`.
