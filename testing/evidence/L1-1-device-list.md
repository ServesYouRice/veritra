# L1 step L1-1: approved-device list, crypto layer (ABI 14)

Date 2026-11-07. Design: `docs/designs/L1-approved-device-list.md`, owner
defaults D94. Nothing is wired into the app, the server or the schema. **Every
new ABI piece needs the Opus review and the independent crypto review the
design asks for before release; neither has been done.** This file is the brief
for them. The `docs/crypto.md` change log entry "L1-1" is the full list.

## What was built

- `crypto/rust/src/l1.rs`: VDL1 encode, strict parse, `list_hash`, the signed
  message, `check_step` (the "Who may sign what" table, `verify_strict`),
  `check_chain`, the summary and chain-result encodings.
- `crypto/rust/src/mls/list.rs`: signing a body as the device, the held
  recovery seed, signing change 4, every leaf as a triple.
- `crypto/rust/src/mls.rs`, `mls/records.rs`, `mls/transfer.rs`, `mls/state.rs`:
  the held seed in the device record, expected-key adds, the added and
  committer pairs on the commit outcome.
- `crypto/rust/src/recovery.rs`: `rk_list_pub` and the list seed.
- `crypto/rust/src/ffi.rs`, `ffi/l1_calls.rs`, the header: status `-11` to
  `-15`, change list version 2, `pm_crypto_l1_*`, `pm_crypto_group_members`,
  `pm_crypto_group_l1_*`, the L1 label on `pm_crypto_c7_sign`, and
  `out_rk_list_pub` on `pm_crypto_recovery_key_derive`.
- Vector `testing/vectors/l1-device-list-v1.json`: two valid chains (every
  change kind), 72 single-fault refusals, four Ed25519 edge cases, all from
  fixed seeds (it regenerates byte for byte).
- Dart: `mobile/lib/crypto/l1_device_list.dart` and the ABI 14 binding.

## Checks run

- `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings`: clean.
- `cargo test` in `crypto/rust`: 178 library tests pass, all other suites pass.
  New: 10 in `l1::tests` (vector file equals what the code produces, chains
  step by step and whole, every refusal for its one reason, the edge cases,
  label disjointness, history rules), 7 in `ffi::l1_tests` (the ABI as Dart
  calls it: signing, chains, recovery hold and sign, keyed adds, commit pairs,
  group members), 4 in `mls::records::records_tests` (held seed survives seal
  and restore; the record is what ABI 13 wrote without a seed and is refused
  by ABI 13's decoder with one; legacy format 3 refuses to drop a seed).
- Go: `go test ./internal/httpapi -run TestVDL1Vector`
  (`server/internal/httpapi/vdl1_vector_test.go`; its helpers carry a
  `vdl1Vec` prefix so they cannot clash with the server step's production
  code). An independent, test-only reimplementation written from the design (not from the Rust code)
  agrees on all 72 refusals, including the reason, signs every step with Go's
  own `crypto/ed25519` byte for byte, and re-derives the list recovery key by
  HKDF. The edge-case test pins where Go's verifier is laxer than the
  clients' strict one (a small-order key with R = identity and S = 0): the
  server must never refuse what a client accepts, and does not.
- Dart (Flutter 3.44.0, native library built with `cargo build --release`,
  `VERITRA_REQUIRE_NATIVE_CRYPTO=1`): `flutter analyze` clean,
  `dart format --set-exit-if-changed .` clean,
  `test/l1_device_list_native_test.dart` (6 tests: both chains step by step
  and whole, every refusal, the derive vector, real devices signing a chain,
  recovery from the held seed and the typed key, keyed adds and commit pairs)
  and the whole `flutter test` run pass (2094 tests, 2 skipped, native
  library present).
- Mutation checks: removing the no-return check in `check_step` fails
  `every_refusal_in_the_vector_is_refused_for_its_one_reason` (case "add of a
  removed device"); disabling the expected-key comparison in
  `stage_membership_commit_checked` fails
  `adds_carry_the_expected_signing_key_and_commits_report_their_pairs`.
- Also run: `go vet ./...` and `go test ./internal/httpapi` (whole package).
- `scripts/verify-mobile-crypto.sh` now also names the nine new exported
  symbols; `nm -D` on the release library shows all nine (the script itself
  needs the Android and iOS artifacts, which CI builds).
- Not run: the `scripts/test` and `scripts/lint` wrappers as a whole (the
  narrower checks above were run), iOS and Android native builds (CI).

## Where the build departs from the design

1. The no-return and one-key-one-device rules over the chain are in Rust
   (`history` argument, `check_chain`), not in Dart. L1-3 must pass its keys
   table to `pm_crypto_l1_check_step`: an empty history only checks `prev`.
2. A listed signing key or recovery key must be a canonical, valid,
   non-small-order point; a recovery-key version must change the key.
3. Change list version 1 is still accepted. L1-3 moves senders to version 2;
   version 1 should then be refused in a later ABI step.
4. Signing runs through `pm_crypto_c7_sign` with the L1 label, as designed,
   but the label is not in the C7 domain list, so `pm_crypto_c7_verify` refuses
   it and raw bytes cannot be signed under it. Rust only parses the body and
   checks account and genesis shape at signing time: the previous version is
   not available there, so `check_step` before use stays mandatory.
5. Change-4 signing does check the whole step (`check_step` against the head
   and history) before returning a signature.

## Questions for the reviewers

1. **Held seed.** It lives in the sealed device record for up to 10 days and
   signs exactly one thing; it is dropped when used. Is the tagged section
   after the transfers, refused by ABI 13, the right shape? Should
   `sign_recovery` keep the seed until the app confirms the server accepted
   the statement (today a lost post means the retype fallback)?
2. **Strict key validity at parse.** Refusing small-order keys closes the
   case where a listed key signs under Go's lax verifier but not the clients'.
   Is anything else about listed keys worth refusing?
3. **Label separation.** `veritra-l1-device-list-sig-v1` is prefix-free with
   the other Veritra labels (tested) and cannot start an MLS `SignWithLabel`
   message (design, "Signing labels"). Confirm.
4. **Apply-then-hold.** The L1 commit calls never refuse a commit for an L1
   reason; the pairs are returned for L1-3 to judge. Confirm this is enough at
   the crypto layer for TASK-006.
