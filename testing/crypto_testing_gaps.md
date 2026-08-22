# Crypto Boundary Testing Gap Audit & Plan

## 1. System Overview & Architecture

The Veritra crypto boundary encapsulates all cryptographic primitives and MLS group messaging logic inside a Rust shared library (`crypto/rust/`) interfaced via a C-compatible FFI ABI (ABI v4 defined in `crypto/rust/include/veritra_crypto.h`) to the Dart Flutter application (`mobile/lib/crypto/native_crypto_bindings.dart` and `mobile/lib/crypto/native_crypto_service.dart`).

- **Ciphersuite**: `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (Classical X25519; post-quantum branches deliberately unreachable).
- **Core Engine**: OpenMLS 0.8.1 / hpke-rs 0.6.
- **Application Framing**: `VAP1` protocol payload format with 256-byte bucket padding.
- **Attachment & Backup Crypto**: AES-256-GCM authenticated chunk streaming with domain-separated AAD and nonce derivation.

---

## 2. Current Test Coverage Inventory

### Existing Rust Tests (`crypto/rust/src/`)
- `attachment.rs:83-99`: `chunk_context_and_order_are_authenticated` (verifies basic chunk encryption/decryption and AAD index authentication).
- `lib.rs:171-248`:
  - `every_production_operation_fails_closed_without_reading_inputs` (verifies `PM_CRYPTO_UNAVAILABLE` fail-closed gate).
  - `credential_boundary_requires_all_device_bindings` (verifies non-empty Account ID, Device ID, and Signing Public Key validation).
  - `key_package_boundary_matches_server_transport_limits` (verifies min/max key package size constraints: 64 to 65,536 bytes).
- `mls.rs:449-640`: 7 unit tests covering basic MLS credential generation, key package validation, and initial state scaffolding.
- `mls/state.rs:252-320`: 3 unit tests covering local state serialization, rollback detection counter, and commit persistence primitives.
- `ffi.rs:715-840`: 3 unit tests checking buffer allocation safety, pointer bounds, and null-pointer defense.

### Existing Dart FFI Tests (`mobile/test/`)
- `native_crypto_bindings_test.dart`: Basic ABI version check and fail-closed gate inspection.
- `app_payload_test.dart`: Serialization, padding verification to 256-byte class, and authenticated payload fields.
- `test_crypto_service.dart`: Mock harness for UI widget tests while real crypto is gated.

---

## 3. Critical Testing Gaps Identified

### Gap CR-01: Lack of Standard RFC 9420 MLS Test Vectors
- **Defect**: The Rust crypto core currently tests against ad-hoc generated synthetic key packages and mock states. There is no automated compliance suite running against published RFC 9420 test vectors (e.g., TreeMath, KeySchedule, MessageProtection, Welcome/Commit validation, and TranscriptHash).
- **Risk**: Interoperability bugs, subtle group state corruption during epoch transitions, and ciphersuite parameter mismatches.
- **Remediation Test Plan**:
  1. Add a dedicated `crypto/rust/tests/rfc9420_vectors.rs` test harness.
  2. Embed verified JSON test vectors for `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`.
  3. Validate TreeMath index calculations, parent hash derivations, and encryption secret derivations against expected vector outputs.

### Gap CR-02: MLS State Rollback & Interrupted Atomic Commit Testing
- **Defect**: While `mls/state.rs` defines a rollback generation counter, tests do not inject real simulated disk faults, process kills, or power interruptions midway through MLS group epoch commits.
- **Risk**: Database/memory desynchronization where the local SQLite message table records a message but the OpenMLS group state remains in the prior epoch (or vice versa), leading to irrecoverable group desync (poison state).
- **Remediation Test Plan**:
  1. Build a fault-injecting mock storage layer in Rust and Dart FFI.
  2. Simulate step-by-step failures during: (a) Proposal generation, (b) Commit generation, (c) Key rotation, (d) SQLite transaction commit.
  3. Assert that both Rust memory state and SQLite disk state roll back cleanly to the pre-commit epoch upon any error.

### Gap CR-03: FFI Boundary Memory Safety, Leak & Panic Auditing
- **Defect**: The C ABI boundary (`ffi.rs`) translates raw pointers across the Dart/Rust boundary. Existing tests do not execute under Memory Sanitizers (ASAN, LSAN, TSAN) or Miri in CI.
- **Risk**: Use-after-free, memory leaks in long-running mobile sessions, unhandled Rust panics unwinding across FFI boundary (causing instantaneous app aborts without crash reports).
- **Remediation Test Plan**:
  1. Implement `catch_unwind` tests across every public FFI export in `ffi.rs`.
  2. Add a CI job running `cargo test` under AddressSanitizer and LeakSanitizer (`RUSTFLAGS="-Zsanitizer=address"`).
  3. Run Miri (`cargo miri test`) over `ffi.rs` buffer handling and pointer slicing routines.

### Gap CR-04: Malicious & Corrupted Payload Negative Testing
- **Defect**: Minimal negative testing for tampered ciphertexts, mismatched group IDs, forged sender signatures, or malformed ASN.1/TLS serialized credentials.
- **Risk**: Cryptographic exception bypass, unhandled panic in OpenMLS parser, or denial-of-service from malformed peer payloads.
- **Remediation Test Plan**:
  1. Construct a comprehensive negative test matrix in `crypto/rust/tests/negative_cases.rs`:
     - Bit-flipped ciphertext chunks.
     - Signature forgery on MLS Commit/Proposal.
     - Replay of past epoch Commit messages.
     - Out-of-order application message injection.
     - Group ID mismatch between transport header and MLS group context.
  2. Verify all operations fail closed with typed, non-leaking error codes.

### Gap CR-05: Attachment & Backup Stream Truncation & Tampering
- **Defect**: `attachment.rs` test only checks valid decryption and 2-byte chunk permutation. It does not test multi-gigabyte chunk sequences, mid-stream truncation, swapped chunk headers, or recovery capability key derivation collisions.
- **Risk**: Silent truncation of downloaded attachments or corrupt partial backups being treated as valid.
- **Remediation Test Plan**:
  1. Test streaming pipeline with simulated 100MB+ attachment streams split into 64KB AES-GCM chunks.
  2. Test final chunk EOF marker validation (detecting missing trailing chunks).
  3. Test backup restoration when recovery capability passphrase has 1-bit corruption.

---

## 4. Execution & Orchestration Specification

### Model & Advisor Assignment
- **Primary Executor Tier**: `Strong` (Protocol & State invariants) / `Balanced+Advisor` (FFI wrappers and vector harnesses).
- **Advisor Requirement**: Mandatory checkpoint with `Strong` (Opus-class) advisor before finalizing state rollback verification and FFI panic-barrier designs.

### XML Execution Prompt Contract

```xml
<role>You are the specialized Crypto Test Engineer for Veritra.</role>
<context>
Review crypto/rust/src/, crypto/rust/include/veritra_crypto.h, mobile/lib/crypto/, and testing/crypto_testing_gaps.md.
</context>
<invariants>
- All operations fail closed under error.
- Never allocate unmanaged heap memory without guaranteed Dart/Rust free lifecycle.
- Zero plaintext leak in error strings or logs.
</invariants>
<instructions>
1. Implement RFC 9420 vector validation in crypto/rust/tests/rfc9420_vectors.rs.
2. Implement FFI panic barrier and catch_unwind tests in crypto/rust/src/ffi.rs.
3. Implement fault-injection state rollback harness in crypto/rust/src/mls/state.rs.
4. Verify tests pass via `cargo test` and sanitizer checks.
</instructions>
<handoff_format>
Task: Crypto Test Remediation
Result: complete | blocked
Checks: cargo test results and vector verification logs
Advisor Checkpoint: Notes on panic barrier and memory leak audit
</handoff_format>
```
