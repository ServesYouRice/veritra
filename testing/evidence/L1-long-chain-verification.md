# L1 bounded long-chain verification (2026-11-11)

Branch: `ai/l1-devices`, following the current-list fix `46d0abf`.
The requested earlier core/server/mobile branches are ancestors of base
`067db28781a2d84654e1528363e988436c21ab2a`; their implementations are reused.

The client previously confused the native chain-call limit (256) with the
total downloadable chain length. An account with 300 valid signed statements
could neither be pinned on first contact nor caught up from version 1. Fork
proofs and authenticated imports had the same batch limit.

The client now downloads up to 4,096 statements, retaining the server's
64-statement pagination. It verifies the first 256 with Rust's chain verifier
and subsequent statements with Rust's step verifier and accumulated history.
No signatures or authorization rules are implemented in Dart. A first-contact
pin is saved only after every downloaded statement verifies. Native history
limits and the download cap still fail closed.

Eight new regressions use the real native library:

- A 300-version chain pins after five pages, recording an add at 257 and
  removal at 258 with their exact historical versions.
- A pinned version 1 catches up to 300.
- A damaged signature after version 256 leaves first contact unpinned.
- A returning removed device at 301 is refused using the accumulated history.
- An interrupted page fetch preserves the durable version 1; retry reaches 300.
- A valid signed fork at 300 is detected from the original genesis.
- Authenticated chain import verifies all 300 statements.
- Downloads stop after exceeding 4,096; oversized imports are refused.

Checks: all 58 L1 Flutter tests passed with `VERITRA_CRYPTO_LIBRARY` set to
this worktree's absolute release DLL path. Go tests and vet passed. Rust tests
passed (223 unit and 7 integration, 8 existing ignored cases); clippy with
`--all-targets -- -D warnings` passed. The repository lint script passed.

`scripts/test.ps1` passed, including release-policy fixtures, Go, Rust and
all 2,614 Flutter tests (22 existing skips). `scripts/lint.ps1` also passed,
including Flutter analyze and formatting of all 443 Dart files.
Two earlier focused invocations included nonexistent guessed test paths;
the corrected invocation enumerated `test/l1_*test.dart` and passed all 58.

This is an additional complete slice of L1, not completion of the package or
independent security review. The design lists remaining product/security work.
ABI 24, local schema 41 and migration 0074 remain unused because no interface
or storage structure changes are required. STATE.md and release gates are unchanged.
