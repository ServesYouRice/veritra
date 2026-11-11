# L1 current-list judgments (2026-11-10)

Base: `067db28781a2d84654e1528363e988436c21ab2a`, branch `ai/l1-devices`.
The requested earlier branches (`origin/agent/l1-core`,
`origin/agent/l1-server`, `origin/agent/l1-3-mobile`) are already ancestors
of the base; no duplicate merge or implementation was needed. Design was
written before implementation in `docs/designs/L1-approved-devices.md`.

The new native Flutter regressions fail on the base's crypto service:

- Signed removal: expected an approval hold, but encryption returned an envelope.
- Incoming changed list: expected hidden text, but the original body was stored.

With this change the 12 native gate tests pass. The signed-removal case uses
real native signatures and the real pin verifier, discovers the removal via
the normal refresh, blocks messages/calls/self-updates, keeps the removed
sender verdict, and permits an MLS removal that releases the hold. It also
checks blocked encryption creates no pending envelope or commit.

Checks on Windows:

- `cargo build --release`: passed; Flutter tests used the absolute worktree
  path `crypto/rust/target/release/private_messenger_crypto.dll` through
  `VERITRA_CRYPTO_LIBRARY`.
- `cargo test`: 223 unit tests and 7 integration tests passed; 8 existing
  ignored vector/measurement cases.
- `cargo clippy --all-targets -- -D warnings`: passed.
- `go test ./...` and `go vet ./...` in `server/`: passed.
- Flutter L1 native/vector/pin/store tests: 45 passed.
- `flutter analyze`: passed.
- Full `flutter test --no-pub --reporter expanded`: 2,606 passed, 22 skipped.
- `scripts/lint.ps1`: passed.
- `scripts/test.ps1`: passed, including policy fixtures, Go, Rust and all
  2,606 Flutter tests (22 skipped).

A first redirected test-script invocation stopped when Windows PowerShell
treated expected negative-fixture stderr as a terminating error. It was rerun
without redirection and passed. One overlapping Flutter invocation failed to acquire the
SQLite DLL; the serial rerun passed. An intermediate file-encoding error was
corrected and the analyzer rerun passed.

No counter, dependency, release gate, server plaintext path or `STATE.md`
change. This is a complete regression-fix slice, not completion or independent
security review of all L1 follow-ups. The integration design lists those gaps.
