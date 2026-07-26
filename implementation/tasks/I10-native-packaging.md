# I10 — Package Rust for Android/iOS

Goal: produce reproducible native OpenMLS libraries for every supported mobile architecture without activating production crypto.

Read:

- `crypto/rust/Cargo.toml`, `crypto/rust/include/veritra_crypto.h`
- Android and iOS build configuration under `mobile/`
- CI/release workflows

Do:

1. Pin Rust targets/toolchain and build the required Android ABIs and iOS device/simulator slices.
2. Package libraries/headers in the normal Flutter platform layout.
3. Record source revision and dependency/license metadata.
4. Add CI compile/link checks and a minimal ABI availability smoke test.
5. Keep `PM_CRYPTO_UNAVAILABLE` active.

Done when: clean Android and no-codesign iOS builds link the exact pinned libraries for supported targets.

Verify: Rust tests plus Android release and iOS no-codesign build jobs.

Do not commit machine-local build outputs or publish artifacts.
