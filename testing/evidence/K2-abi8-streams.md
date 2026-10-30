# K2 ABI8 bounded bundle streams - 2026-10-29

Native stream operations20-25 and matching Dart bindings are implemented.
This does not wire the durable app enrollment/cache/transport/import flow and
does not qualify phone memory use or open a release gate. Final independent
stream review and combined repository checks belong to the coordinator.

Boundary contract: [`K2-abi8-boundary.md`](../../docs/designs/K2-abi8-boundary.md).
Code: `crypto/rust/src/ffi/k2/streams.rs`, internal history/transfer helpers,
the C header and `mobile/lib/crypto/k2_native_streams.dart`.

- Chunk-fed/read framing is bounded, sequential and exact. One process-wide
  large-stream lease prevents simultaneous large bundle allocations.
- Stream ownership uses a weak device reference. Device destruction invalidates
  and wipes its stream and releases the lease; the remaining stream handle can
  still be destroyed exactly once. Same-record mutations and expiration are
  blocked while leased. The only exception is incoming Ready-to-Importing after
  full plaintext authentication, preserving the verified capability and stream.
- Incoming reads cannot return plaintext before the entire ciphertext matches
  its source-authenticated digest/size/header and every chunk/padding check.
  Results expose authenticated header counter/version/creation time so the
  importer can compare those with inner snapshot metadata.
- The source derives transferID as lowercase hex64 of
  `SHA256(raw("veritra-k2-transfer-id-v1") || transcriptHash32 || ciphertextSHA25632)`
  and signs it inside the handoff. Recipient begin checks the same derivation.
  Source Ready state cannot regenerate a new bundle; application code must
  durably retain the exact ciphertext/metadata before its first upload.
- Payload/frame buffers use existing zero-on-drop secret wrappers. Output
  ownership uses the single strengthened buffer-free contract. Dart returns
  caller-owned plaintext chunks that the importer must wipe after consumption.

Pinned Windows Rust1.91.0 checks, from `crypto/rust`:

```text
cargo +1.91.0-x86_64-pc-windows-msvc test --locked -j1
PASS:56 unit +2 integration;1 cap measurement and2 older measurements ignored
cargo +1.91.0-x86_64-pc-windows-msvc fmt --check
PASS
cargo +1.91.0-x86_64-pc-windows-msvc clippy --locked -j1 --all-targets -- -D warnings
PASS
cargo +1.91.0-x86_64-pc-windows-msvc build --locked -j1
PASS
```

Separate exact-cap test, run alone:

```text
cargo +1.91.0-x86_64-pc-windows-msvc test --locked -j1 ffi::k2::streams::tests::maximum_bundle_allocation_measurement -- --exact --ignored --nocapture --test-threads=1
PASS:47.07s
K2_CAP payload_bytes=67108856 padded_bytes=67108864 peak_extra_allocated_bytes=202378334 baseline_bytes=1071482
```

The test-only System allocator measured about193.0MiB extra live Rust
allocations, under the200MiB (209715200-byte) budget. It streamed source output
to a ciphertext-only file, then authenticated/read the full recipient bundle.
This is a native allocation measurement, not process RSS: it excludes the
Flutter/Dart exporter/parser and runtime baseline and does not establish mobile
suitability. The allocator override is compiled only in Rust unit tests.

With the rebuilt real ABI8 DLL, the pinned Flutter tool snapshot ran:

```text
test --no-pub --concurrency1 test/k2_native_streams_test.dart test/k2_native_controls_test.dart test/native_crypto_bindings_test.dart
PASS:5 tests,0 skipped
dart analyze lib/crypto/native_crypto_bindings.dart lib/crypto/k2_native_controls.dart lib/crypto/k2_native_streams.dart test/k2_native_streams_test.dart test/k2_native_controls_test.dart
PASS:no issues
dart format lib/crypto/k2_native_streams.dart test/k2_native_streams_test.dart
PASS:0 changes
```

The batch launcher could not find PowerShell in PATH; invoking the installed
`dart.exe` with `flutter_tools.snapshot` exercised the same pinned Flutter test
tool successfully. DLL SHA256:
`cb47052648129fcca32779fe46525ed7911dad753b462e5bae466281faf79d06`.

Tests cover multi-chunk roundtrip, read-before-auth refusal, tampering,
sequential offsets, incomplete payloads, wrong owner, same-record lease guards,
verified-only Importing, sealed-state import restart, cap bounds, output alias
refusal, and stream invalidation after device destruction. No claim is made
about cache-loss recovery, local SQL import durability or actual server upload;
those require the application orchestration slice.

## Peer-review follow-up

The coordinator found an early Dart decoder failure path that could retain an
owned plaintext result when the outer native frame header/version/op/size was
invalid. The shared owned-result decoder now wipes that allocation before
rethrowing, including failures before `read()` starts. A pure frame regression
checks malformed magic/version/op/truncation/size/inner length and successful
view ownership without substituting fake cryptography. Source formatting passes.
The coordinator subsequently reported the updated stream suite **3 passed** and
the whole Dart analyzer clean after this fix. These checks were serialized with
the shared Android build to avoid the host's observed Windows virtual-memory
exhaustion.
