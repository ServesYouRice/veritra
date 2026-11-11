# C3 remote-removal obligations — 2026-11-11

Scope: review finding on removals observed from another device/moderator.
Earlier `origin/agent/c3` work is inherited; its history and the current diff
were inspected before changes. The private-info key-home guard is retained.
C3 as a whole remains incomplete.

## Change

`NativeCryptoService` processes remote commits through the existing ABI 13
outcome API. A surviving member stores the authenticated removal epoch with
MLS state, cursor and processed-message marker. The unused exporter root is
wiped. Both local stores implement the same transition; no schema migration
is required because it uses the encrypted metadata table.

The foreground AppState refresh maps the watermark to the shared/community
or private-channel key home. Commits invalidate the refresh throttle; an
inbound-only wake persists the obligation without outbound work. Missing
topology can be loaded later without losing the obligation. Edits, add-key
delivery and key answers check the native watermark before using an old key.
A new removal invalidates an ongoing rotation. Completion records only the
epoch that the pass handled, separately from the native watermark.

Chosen design option: C3's recommended (a), remaining owner/admin devices
rotate for remote/moderator removals. Non-admins retain the obligation for
promotion. Device removals conservatively rotate as well as account removals.

## Verification

- Final focused service/native/store suite: 106 passed, no skips. Native
  suite separately: 12 passed, including bounded cancellation/retry.
- Tests cover shared/private rotation after restart, edits refused before the
  observation pass, repeated observation, non-admin promotion, and a newer
  removal arriving during key delivery. Existing private-rotation tests also
  prove that an excluded member's old key cannot open the new record.
- Real OpenMLS tests distinguish add-only commits, surviving removals and
  self-removal. A cancelled bounded transition restores native state and
  commits no watermark; retry succeeds and replay does not advance state.
- SQLite failure injection checks every transaction boundary: neither the
  watermark nor MLS state/cursor survives a rejected transaction.
- Flutter analyze: pass. Full lint script: pass (Go vet, Rust fmt/clippy,
  Flutter analyze/format). Full test script: exit 0, including every Python
  policy fixture, `go test ./...`, 230 Rust tests (8 existing ignores), and
  2,464 Flutter tests (21 existing skips). Native Flutter tests used this
  worktree's absolute release DLL via `VERITRA_CRYPTO_LIBRARY`.
- `git diff --check`: pass. Scripts were launched through a child PowerShell
  with process-level output redirection, avoiding the outer PowerShell
  treatment of ordinary native stderr as a command failure.

Initial focused failures exposed two fixture/integration mistakes: restarted
test devices reused a deterministic RNG seed, and database metadata writes
needed the LocalStore `setting:` namespace. Both were corrected before the
passing focused runs.

## Limits

No production verified C4 role source/restriction flag, encrypted-only
creation/plaintext refusal and column removal, channel conversion,
category/icon screens or complete production C3 acceptance evidence were
added. The rotation service tests supply verified roles; they do not prove
production C4 wiring. These remain open review findings.

No STATE.md, release-gate, dependency, ABI, schema or migration changes.
Reserved local schema 35 and server migration 0067 remain unused. Work was
performed alone; no push, PR or CI changes.
