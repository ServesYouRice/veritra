# C4 review follow-up: durable local observations (2026-11-11)

Package status: **partial**. This closes observation persistence from finding 1
of `.ai-review.md`; it does not finish C4. Equality and the four requested
command regression cases were already committed in `508e50c` and were rerun.
The remote-branch scan found no matching unmerged C4 branch to port.

## Change exercised

- Assigned local schema **38** creates `local_governance_observations` on new
  databases and upgrade. ABI 22 and server migration 0071 remain unused.
- Incoming MLS transitions, accepted local commits and outgoing application
  messages reduce observations inside their existing guarded transactions.
  No standalone write is exposed through `LocalStore`.
- SQLCipher restart preserves exact timestamps and election identity. Owner
  activity blocks voting; ownership changes reset inactivity; cancellation
  drops election clocks. Backward time does not move activity backward.
- Every incoming transaction failure boundary rolls clocks back with MLS state,
  replay marker and cursor; retry succeeds. Stale/replayed transitions refuse.
- Clocks survive a cache clear with retained MLS state, but do not travel in
  backups. Identity/crypto replacement, group deletion and reset discard them.
  A group deletion overrides an observation in the same transaction.
- Schema 34 upgrades to 38 with no inferred historical activity. A failed
  upgrade rolls table creation and version back, and a subsequent open succeeds.

## Checks

- Focused Flutter run: **224 passed**, no skips. Includes C4 command, codec,
  rules and real-native MLS tests; observation storage; encrypted local store,
  schema creation, K2 enrollment and D70 record regressions.
- Final full Flutter run: **2688 passed, 22 skipped**, exit 0. This includes
  the final observation tests against the production SQLCipher factory.
  `VERITRA_CRYPTO_LIBRARY` pointed to this worktree's existing release DLL at
  `C:\tmp\vw\wt\c4-rest\crypto\rust\target\release\private_messenger_crypto.dll`.
- `go test ./...`, `go vet ./...`: passed.
- `cargo test`: 223 unit tests and 7 integration tests passed, 8 ignored.
- `cargo clippy --all-targets -- -D warnings`: passed.
- `scripts/lint.ps1`: passed, including Flutter analysis and formatting
  (452 files, zero changes on the final run).
- `scripts/test.ps1`: passed, exit 0, including all ten policy fixture suites,
  Go and Rust tests and the full Flutter suite (2688 passed, 22 skipped).
- `git diff --check`: passed.

## Boundaries and remaining work

The C4 design and STATE.md explicitly prohibit receiver wiring before C1
authenticated removal proofs exist. The server still supplies pending
membership changes; the app has no leaver-signed proof validator. Wiring
succession now would retain the documented forced-removal takeover attack.
The new storage effects therefore have no app receiver caller yet.

Remaining: removal proofs and receiver authorization; role rosters derived
only from L1-approved leaves; all producers and two-phase receivers together;
automatic owner cancellation; role/election UI; server succession; any needed
ABI 22 and migration 0071 work. The full-package finding remains open.

No dependency additions, server plaintext paths, STATE.md edits or release
gate changes. Worked alone as requested; no independent review claimed.
