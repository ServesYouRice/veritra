# QA05 — Test the mobile backup crypto pipeline

| Field | Contract |
|---|---|
| Confirmed source | `testing/review_findings.md` M2 at `3ee785d` |
| Canonical owner | T45C mobile recovery; coordinate T45A atomicity |
| Routing snapshot (board wins) | Blocked by I29, I39, and T45A |
| Risk | High recovery and key-ownership boundary |
| Executor | Balanced+advisor for tests only |
| Advisor | Required before production edits or recovery-code assertions |
| Depends on | T29, T39, T45A; pinned native crypto library |
| Blocks | T45C/G24 mobile restore evidence |
| Parallel safety | Do not overlap QA04 or another backup/recovery owner |

## Objective

When I45 becomes eligible, prove backup creation/upload/recovery framing,
cleanup, and failure atomicity around the real Rust chunk primitive and a local
fake HTTP service. Do not design or activate recovery under this task.

## Read first

- `docs/audit-consensus.md` I45 and I29/I39 dependencies.
- `implementation/tasks/T45A-backup-restore-atomicity.md` and
  `implementation/tasks/T45C-mobile-recovery.md`.
- `mobile/lib/crypto/backup_service.dart`, relevant backup methods in
  `api_client.dart`, `MemoryLocalStore`, and native binding tests.

## Confirm first

After the coordinator marks dependencies complete, verify no mobile test names
or instantiates `BackupService`. If direct coverage already satisfies every
criterion below, return `stale`. Until then, make no edits and return `blocked`.

## Allowed write set

- New `mobile/test/backup_service_test.dart` and narrow test helpers.
- `mobile/lib/crypto/backup_service.dart` only for a reproduced defect and only
  after advisor approval.
- A minimal constructor seam for the internally created `ApiClient` only if a
  loopback `HttpServer` cannot cover recovery without changing behavior.

Do not edit recovery UI, capability ownership, server backup semantics,
`LocalStore` transaction behavior, native algorithms, or dependency manifests.

## Invariants

- Recovery token/key material remains user-held and never appears in server
  state, logs, exception text, or test output.
- Restore is all-or-nothing: corrupt/wrong-key/interrupted data preserves the
  prior local state.
- Temporary ciphertext is invocation-owned and removed on success and failure.
- The suite uses the real pinned native library; fake crypto is insufficient.

## Work

1. Use `MemoryLocalStore`, a loopback `HttpServer`, and a temporary application
   support directory. Capture upload bytes in memory without logging them.
2. Cover missing MLS state, empty/oversized export, upload failure/interruption,
   successful upload metadata, and recovery-code shape without asserting the
   secret value.
3. Round-trip a valid backup into a separate store and assert exact restored
   state/counter behavior allowed by the approved T45 design.
4. Reject malformed code, wrong key/token, bad magic, invalid bounds, bad chunk
   length, truncation, extension, and authentication failure.
5. Inject restore failure and prove prior state remains usable. Verify cleanup
   of current and expired orphan files without deleting unrelated files.

## Acceptance

- Valid create/upload/recover passes against the real native primitive.
- All malformed, interrupted, and wrong-key cases fail closed and retain the
  original local state.
- No recovery secret reaches logs or the fake server beyond the opaque token
  required by the approved endpoint contract.
- Temporary file ownership and cleanup are proven.
- No recovery UI or server plaintext path is introduced.

## Required checks

```sh
cargo build --manifest-path crypto/rust/Cargo.toml --locked --release
cd mobile && VERITRA_CRYPTO_LIBRARY=../crypto/rust/target/release/libprivate_messenger_crypto.so flutter test test/backup_service_test.dart test/encrypted_local_store_test.dart
cd mobile && flutter analyze
```

Also run the full repository test wrapper. Missing I45 dependencies or native
tooling means `blocked`, not complete.

## Advisor checkpoint

Before writing production code, send the approved T45 restore atomicity rule,
the failing fixture, and the proposed change. Ask whether the fixture models
key ownership and rollback correctly rather than inventing a recovery design.

## Handoff

Use the workflow handoff with `Task: QA05`. State dependency status first and
list every failure fixture without printing any generated code/token/key.
