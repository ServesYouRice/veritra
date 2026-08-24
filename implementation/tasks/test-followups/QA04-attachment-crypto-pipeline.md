# QA04 — Test the mobile attachment crypto pipeline

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M2 at `3ee785d` |
| Canonical owner | Follow-up to completed I17; G24 activation evidence |
| Routing snapshot (board wins) | Prepared; coordinator must add/map a canonical board child before claim |
| Risk | High crypto-boundary verification |
| Executor | Balanced+advisor |
| Advisor | Required before changing framing, context, or destination semantics |
| Depends on | Pinned native crypto library and continued fail-closed UI |
| Blocks | Any attachment UI activation and its G24 evidence |
| Parallel safety | Do not overlap QA05 or another mobile crypto test owner |

## Objective

Exercise the real Dart file/framing/cleanup pipeline around the pinned Rust
attachment primitive without enabling attachment UI or replacing the reviewed
cryptographic algorithm.

## Read first

- `AGENTS.md` crypto/storage boundaries and `docs/board.md` completed I17 plus
  crypto-gated mobile UI.
- `mobile/lib/crypto/attachment_crypto.dart` and
  `mobile/lib/crypto/native_crypto_bindings.dart`.
- `mobile/test/native_crypto_bindings_test.dart`, CI's native-library setup,
  and Rust attachment chunk tests.

## Confirm first

Run `rg -n "AttachmentCryptoService|encryptFile|decryptFile" mobile/test`.
If a direct pipeline suite now covers the acceptance cases below, return
`stale`. Rust-only chunk tests and source inspection do not satisfy this task.

## Allowed write set

- New `mobile/test/attachment_crypto_test.dart` and narrow shared test helpers.
- `mobile/lib/crypto/attachment_crypto.dart` only for a defect first reproduced
  by the new test and approved at the checkpoint.

Do not edit Rust algorithms/FFI ABI, native platform code, chat UI, API/upload
code, dependency manifests, or crypto gates.

## Invariants

- Tests use `NativeCryptoBindings.open(VERITRA_CRYPTO_LIBRARY)` and the pinned
  compiled library; a fake cipher cannot be the only proof.
- Context remains `conversation_id + NUL + action_id`; nonce/key sizes and the
  one-MiB chunk bound remain unchanged.
- Failure/cancellation leaves no plaintext destination or temporary
  ciphertext/`.part` file and does not destroy a pre-existing destination.
- Test names/logs never print keys, plaintext, ciphertext, or manifests holding
  key material.

## Work

1. Point the path-provider test channel at a unique temporary directory and
   guarantee teardown.
2. Round-trip deterministic binary inputs at 1 byte and around the chunk
   boundary; assert manifest types/bounds, ciphertext length, and exact output.
3. Tamper one ciphertext byte and separately change the key, conversation,
   action, chunk count, plaintext size, and framing length. Each must fail
   closed with no partial destination.
4. Cover truncated and extended ciphertext, unsupported manifest version,
   empty/oversized source, and cancellation during encrypt/decrypt.
5. Prove `PreparedEncryptedAttachment.cleanup()` and every error path remove
   owned temporary files. Do not assert stream-emission-dependent chunk counts;
   escalate if framing is not deterministic enough for the product contract.

## Acceptance

- The real Rust-backed pipeline round-trips every valid boundary fixture.
- Every corrupt/context/wrong-key/bounds fixture fails before publishing a
  plaintext destination.
- Cancellation and failures clean only invocation-owned temporary files.
- CI executes the test with a native library; it is not accepted as a skip.
- Attachment controls remain unavailable.

## Required checks

```sh
cargo build --manifest-path crypto/rust/Cargo.toml --locked --release
cd mobile && VERITRA_CRYPTO_LIBRARY=../crypto/rust/target/release/libprivate_messenger_crypto.so flutter test test/attachment_crypto_test.dart
cd mobile && flutter analyze
```

Use the platform-equivalent library filename on Windows/macOS. Also run the
repository test wrapper once the focused suite passes.

## Advisor checkpoint

Before any production edit, show the failing fixture and proposed smallest
change. Ask specifically whether it preserves the reviewed context, bounds,
atomic destination rule, and cross-platform framing.

## Handoff

Use the workflow handoff with `Task: QA04`. List every byte-size/tamper fixture
and explicitly confirm the fail-closed UI was not changed.
