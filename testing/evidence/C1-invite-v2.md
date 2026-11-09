# C1 invitation binding v2: evidence

2026-11-07, branch `agent/invite-v2`. Design: `docs/designs/C1-invite-format.md`.
Original branch counters: crypto ABI 13, mobile local schema 20, server
migration 0052. The 2026-11-09 port below supersedes these reservations. Not done: the independent security review.

## Rust (`crypto/rust`)

- `cargo test --lib`: all pass, including
  `c7::invite_binding_tests::the_vector_matches_the_written_layout`,
  `no_signing_domain_is_a_prefix_of_another` and the existing MLS test that
  signs and verifies in every domain (now three).
- `cargo build --release` builds the library the native Dart tests use.

## Go (`server`)

- `go test ./internal/storage ./internal/httpapi`: pass. New or changed:
  `TestInviteBindingV2Vector` (rebuilds the message and signature from the
  shared vector with `crypto/ed25519`), `TestInviteWithoutSignatureIsReturnedEmpty`
  (a pre-0066 row), signature length refusals in
  `TestInviteBindingMustMatchTheCreatingDevice`, the handler tests.
- The migration is applied by every storage test (they run all migrations).

## Dart (`mobile`)

- `flutter analyze`, `dart format --set-exit-if-changed .`: clean.
- `membership_invite_link_test.dart`: v2 link parse and rejection (v1,
  missing or non-canonical commitment), commitment vector, signed message
  fields and locator, vector file.
- `app_state_membership_test.dart`: link made with commitment and signature;
  a preview or request is refused for a bad or missing signature, a key that
  does not fit the commitment, a roster that names another key, and a build
  without the engine; a v1 link is not read; the roster is a no-op without a
  shared group.
- `invite_binding_native_test.dart` (native, `VERITRA_CRYPTO_LIBRARY`): the
  vector signature through `pm_crypto_c7_verify`, a real device signature, a
  second device verifying it, tampering, and the roster key read from a real
  MLS group.

## 2026-11-09 port on ai/c1-invites

Base `0d09fcb36a06d9bc309bba226b8bc95997f499b8`; ported `f10ce21` and
`974dd98` rather than recreating them. Assigned counters: crypto ABI 21,
local schema 32, server migration 0066. No dependency added.

Group-only D99 slice: verified anchor stored before sending a request,
including a lost response; target group id checked by existing OpenMLS join,
and inviter leaf key checked before seal/cursor/marker writes. Rejection
restores committed crypto state and uses the existing conversation pause UI.
The local table survives reopen, upgrades from 31 atomically, and is cleared
with identity replacement, backup restoration and full wipe. No fragment,
secret, locator or signed binding is retained in it or exported in backups.

Focused checks:
- Go `go test ./...` and `go vet ./...`: pass (all server packages).
- Rust `cargo test -- --test-threads=1`: 223 unit + 7 integration pass;
  measurement tests remain ignored. `cargo clippy`: pass.
- `cargo build --release`: pass, ABI-21 Windows DLL built locally.
- Flutter membership parser/API/actions/widgets + anchor-store tests: pass
  (71 including six native tests and anchor-write failure).
- Native invitation tests: 6 pass with VERITRA_CRYPTO_LIBRARY set to that
  DLL and VERITRA_REQUIRE_NATIVE_CRYPTO=1, including successful Welcome,
  changed key, missing inviter, wrong MLS target, restart and rollback.
- `scripts/lint.ps1`: pass (Go vet/format, Rust all-target clippy/format,
  Flutter analyze and formatter).

Initial Rust compilation exceeded the Windows paging file; retry with
CARGO_BUILD_JOBS=1 and dev/test debug info disabled passed. An initial native
fixture produced no Welcome because it did not enroll peers in the existing
L1 test list; updated it to use TestNativeCryptoService, preserving the L1
add gate. The native tests now exercise a nonempty real Welcome.

Solo self-review against docs/crypto.md: Rust changes are the existing
sign-domain allowlist and ABI pin only; no MLS processing, release gate,
server plaintext path, or new dependency. An independent security review
has not happened (owner required solo work). C1 is partial: community shared
group anchoring and W11/C3 encrypted rename wiring remain, plus real-device
and community lifecycle evidence. Existing membership approval/removal and
username UI are retained and exercised by the focused tests.

The first full Flutter run exposed older-schema fixtures that retain new
tables. The new table creation now uses `IF NOT EXISTS`, matching adjacent
migration helpers, and has an explicit retained-table regression test.
A concurrent full-script Flutter launch also hit Windows' locked
`build/native_assets/windows/sqlite3mc.dll`; full checks are being repeated
serially. These failures are not counted as passes.

Final checks after the migration correction:
- Six storage/search/migration suites: 95 pass, including the retained-table
  regression, encrypted-store rollback and old-schema upgrades.
- `scripts/lint.ps1`: pass again after the correction.
- `scripts/test.ps1`: release-policy fixtures, Go and Rust pass; Flutter
  finishes with 2359 passed, 21 skipped and 2 failures. Both failures are in
  `device_link_v3_flow_test.dart`: "an approval read after the link window
  still finishes" and "a waiting claim inside its expiry survives a status
  error". A focused two-test rerun confirms `PathAccessException`, Windows
  error 32, at `_withWorld`'s temporary-directory deletion (line 636).
  No assertion in the link flows fails in that rerun. These tests remain
  failing; no full-suite green result is claimed. Production link code and
  its test file are unchanged by this port.
