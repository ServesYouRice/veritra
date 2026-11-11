# C4 package review (2026-11-11)

Reviewed `5b9cff9cce2c5a6bbed8df3a5aa05746ccd30659..d67343d` on
`ai/c4-rest`, including the author's `.ai-report.md` and the adjacent rules,
native carrier and app call sites. An independent review agent also examined
the command planner and storage ordering. No additional definite runtime bug
was found in this slice.

## Blocking finding: package incomplete

The change adds a command planner and durable observation storage, but no
app caller constructs `GovernanceCommands` or `GovernanceObservationChange`.
`NativeCryptoService` still creates ordinary groups and processes incoming
commits through the existing path, rather than the role-aware genesis and
two-phase authorization path. Existing posting checks cannot provide C4's
promise without an authenticated, maintained governance record.

Still required: C1 authenticated removal proofs; L1-approved leaf rosters;
coordinated role producers and receivers; automatic owner cancellation;
role/election UI; and server succession. The design explicitly blocks receiver
wiring until the removal proofs exist. The three-device native test exercises
the primitives and rules directly; it does not demonstrate app enforcement.
The package must remain partial.

Schema 38 is the assigned counter and is used for the local clocks. The active
crypto ABI remains 21; ABI 22 and server migration 0071 are unused reservations.
No counter collision, dependency addition, server plaintext path or weakening
of release gates was found in this diff.

## Review fixes

- Updated STATE.md's C4 row: removed the stale claim that the rules engine
  still uses oldest-admin inheritance, recorded the tested slice and listed
  the outstanding work.
- Corrected the design's stale assertion that the carrier and local storage
  are unbuilt/unneeded. No runtime behavior or protocol decision changed.

## Checks

- Focused Flutter rules/codec/command/observation/native tests: 110 passed,
  no skips, using VERITRA_CRYPTO_LIBRARY.
- Flutter analysis: passed, no issues.
- Full Flutter suite: 2688 passed, 22 skipped, exit 0.
- Go test ./... and go vet ./...: passed.
- Cargo test: 223 unit and 7 integration tests passed; 8 ignored.
- Cargo clippy --all-targets -- -D warnings: passed.
- scripts/lint.ps1: passed, including analysis and formatting (452 files,
  no changes). An initial redirected invocation hit Windows PowerShell's
  native-stderr handling; the normal invocation passed.
- scripts/test.ps1: passed, exit 0, including all ten policy fixture suites,
  Go, Rust and Flutter (2688 passed, 22 skipped). An initial redirected
  invocation hit the same PowerShell native-stderr issue; the normal run passed.
- git diff --check: passed.
