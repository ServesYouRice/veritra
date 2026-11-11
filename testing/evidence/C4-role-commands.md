# C4 role command producer slice — 2026-11-11

Worktree `ai/c4-rest`, base `5b9cff9cce2c5a6bbed8df3a5aa05746ccd30659`.
This is a partial C4 delivery, not full app wiring.

## Exercised behavior

- Typed role-only commands produce canonical records accepted by the existing
  receiver rules: promote, demote, step down, elector confirmation, posting
  settings, transfer, election open/close/cancel, vote and no-admin claim.
- Owner promotions choose electors; peer promotions do not. Admin seniority is
  retained until demotion; re-promotion and an old owner's transfer restart it.
- D81's 30-day inactivity wait and 7-day election wait use local observations;
  stale owner/election observations and future timestamps refuse commands.
- Local observation updates track authenticated activity, cancellation and
  ownership changes; missing observations conservatively start the waits now.
- D82/D86 exclude stand-ins promoted after `ownerRev`. A strict majority's
  deciding vote transfers ownership in the same record and clears the election.
- A real three-device MLS test stages and merges promotions, posting settings,
  opening, a non-deciding vote and a deciding vote, checking identical records
  on all three devices after every commit.

## Checks

- `cargo build --release`: passed; built the worktree's native DLL.
- `VERITRA_CRYPTO_LIBRARY` set to the absolute worktree path
  `crypto/rust/target/release/private_messenger_crypto.dll` for native Flutter
  tests.
- Focused Flutter run: `governance_commands_test.dart`,
  `c4_roles_native_test.dart`, `governance_test.dart`,
  `governance_codec_test.dart`: **86 passed**, none skipped.
- Full Flutter suite: **2662 passed, 22 skipped**. This run preceded the final
  observation-reducer additions, which the final focused run exercises.
- Final `flutter analyze --no-pub`: passed, no issues.
- `go test ./...` and `go vet ./...`: passed.
- `cargo test`: 223 unit tests and 7 integration tests passed; 8 measurement
  tests ignored. `cargo clippy --all-targets -- -D warnings`: passed.
- `scripts/lint.ps1`: passed on rerun, including `cargo fmt --check`, clippy,
  Go vet, Flutter analysis and Dart formatting (449 files, zero changes).
- `git diff --check`: passed.
- `scripts/test.ps1`: stopped after its first two fixture suites passed,
  because Windows PowerShell treated the Dart-retraction fixtures' expected
  negative-test stderr as a terminating native error. All eight remaining
  Python fixture suites were run directly and passed. The Go, Rust and
  Flutter suites were run separately as listed above; no aggregate-script
  success is claimed.

An initial redirected lint invocation stopped on normal Cargo stderr under
Windows PowerShell; a direct rerun passed. One overlapping focused Flutter
invocation hit Windows' loaded SQLite DLL lock; the final sequential rerun
passed. No source workaround was needed.

## Boundaries and remaining work

No new dependencies, wire format, ABI, local schema or server migration.
Assigned counters 22, 38 and 0071 are unused by this slice. `STATE.md`,
production crypto gates and release checks are unchanged. Work was performed
alone as instructed, so no independent review is claimed.

The design's C1 authenticated-removal prerequisite is still unmet. Before
enabling C4 in the app: implement those proofs and validation, derive role
rosters only from L1-approved leaves, wire all producers and two-phase
receivers together, persist observations atomically, schedule owner
cancellation, add role/election UI and server succession. The command planner
does not itself authenticate leaves, send commits or persist observations.
