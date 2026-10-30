# K2 ABI8 control boundary evidence

2026-10-28, Windows x64, Rust1.91.0 MSVC, locally installed Flutter/Dart.
This is the control/binding slice only. It does not make K2 history transfer
usable: bundle streams, durable enrollment orchestration and importer wiring
remain separate work. Production crypto availability stays gated.

## Implemented boundary

* Rust/header/Dart agree on ABI8. Existing ABI7 operations retain behavior.
* Eleven exported K2 control operations use bounded64KiB PK2Q/PK2R framing,
  BE lengths/integers, exact field sizes and no trailing bytes.
* Source confirmation exposes only durable-intent timestamp. No approval tag
  is returned by source accept, inspect or confirmation; a separate accessor
  requires existing native intent. Service must commit intent first: the native
  boundary cannot prove SQL durability and does not pretend a counter proves it.
* Incoming keys remain native and stable across seal/restore and exact retry.
  Signed enrollment uses stored context and a validated key package matching
  local credential and signing key. Signature/request hash repeat identically.
* The existing output-free function now transfers the exact allocation into
  SecretVLBytes for its zeroize-backed, non-elidable clearing. No new allocator
  or free function. New control output buffers allocate their final size once.
* Dart low-level request/result types include role-aware stage4 decoding:
  source Posted, recipient Importing. No shared application/store code changed.

## Real checks

All commands completed successfully against the changed code:

```
cargo +1.91.0-x86_64-pc-windows-msvc test --locked -j 1 --lib ffi::k2
  3 focused tests pass
cargo +1.91.0-x86_64-pc-windows-msvc test --locked -j 1
  54 unit tests +2 integration tests pass;2 measurements intentionally ignored
cargo +1.91.0-x86_64-pc-windows-msvc clippy --all-targets -j 1 -- -D warnings
cargo +1.91.0-x86_64-pc-windows-msvc fmt --check
cargo +1.91.0-x86_64-pc-windows-msvc build --locked -j 1
```

Fresh matching library:
`crypto/rust/target/debug/private_messenger_crypto.dll`.

Using the installed Dart executable and Flutter tool snapshot directly (the
Windows SDK batch launcher did not complete under the sandbox):

```
dart analyze lib/crypto/native_crypto_bindings.dart
  lib/crypto/k2_native_controls.dart test/k2_native_controls_test.dart
  test/native_crypto_bindings_test.dart
  No issues found
VERITRA_CRYPTO_LIBRARY=<absolute matching debug DLL>
dart <Flutter SDK>/bin/cache/flutter_tools.snapshot test --no-pub --concurrency=1
  test/k2_native_controls_test.dart test/native_crypto_bindings_test.dart
  3 tests pass,0 skipped
```

Flutter initially could not open its SDK cache lock under sandbox permissions.
The same focused test command succeeded with approved SDK-cache access; this
was not a test failure. Strict clippy initially rejected a variant named
ApprovalRequest inside Request; renamed it ApprovalRead and reran successfully.

Coverage includes source intent persisted/reopened before tag accessor;
recipient key reuse after restart; exact signed proof retry; substituted
key-package and wrong-role refusal; original L0-v2 native lifecycle; every
truncated receive-control prefix; extra/version/op mismatch; changed secret;
null and overlapping outputs without state mutation; invalid import/post stages;
idempotent approval/forget; explicit expiry. Full Rust suite also exercises
genuine v2 state migration, importing crash replay and bounded late approval.

Repository-wide test/lint checks are coordinated by root against the shared
worker checkpoint. No stream memory measurement exists yet;200MiB is a proposed
cap to measure during the stream slice, not evidence of mobile suitability.
