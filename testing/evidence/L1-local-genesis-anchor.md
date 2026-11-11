# L1 local genesis anchor (2026-11-11)

Branch: `ai/l1-devices`, following `46d0abf` and `81906db`.
The earlier L1 core, server and mobile branches are ancestors of the assigned
base and remain reused.

Setup and invitation registration previously read the account's server list
before pinning their own signed genesis. A missing, empty or failed response
skipped the pin; a later refresh could then trust a different genesis on first
use. The client now pins its locally signed statement directly. Network reads
cannot discard that anchor. Refreshes still use native chain verification and
cannot replace the original list identity with a server-controlled genesis.

Six new native tests cover setup and registration with empty, missing and
unavailable list reads, followed by an attacker-signed genesis. They assert
the original statement stays pinned, the local key stays approved, and the
attacker remains unknown without creating a sticky conflict. The migration
test now starts from an actual pre-L1 identity with no signed genesis, rather
than a newly created account whose server ignores the submitted genesis.

Focused verification: all 64 L1 Flutter tests pass using
`C:\tmp\vw\wt\l1-devices\crypto\rust\target\release\private_messenger_crypto.dll`
as `VERITRA_CRYPTO_LIBRARY`. `scripts/lint.ps1` passes, including Go vet,
Rust clippy with warnings denied, Flutter analyze and Dart formatting.
`scripts/test.ps1` passes: policy fixtures, Go tests, 223 Rust unit tests and
7 integration tests (8 existing ignored), and 2,620 Flutter tests (22 existing
skips). `git diff --check` passes.

This slice covers network withholding at setup/registration. It does not make
genesis/session/MLS persistence atomic; storage failure or a crash between
those writes remains a follow-up. Authenticated linked-device anchoring and
the other incomplete L1 product flows remain listed in the design. No
independent review is claimed: the owner requested solo work.

No dependencies, ABI, local schema, server migration, STATE.md or release
gates change. Assigned counters 24, 41 and 0074 remain unused.
