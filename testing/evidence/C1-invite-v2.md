# C1 invitation binding v2: evidence

2026-11-07, branch `agent/invite-v2`. Design: `docs/designs/C1-invite-format.md`.
Counters unchanged: crypto ABI 13, mobile local schema 20. Server migration
0052 added (`binding_signature`). Not done: the independent security review.

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
  (a pre-0052 row), signature length refusals in
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
