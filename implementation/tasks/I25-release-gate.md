# I25 — Independent review and release gate

Blocked by: D05 and completion of I24.

Goal: activate production crypto only after evidence and independent review support it.

Read:

- `scripts/release-readiness.sh`
- `crypto/rust/src/lib.rs`, `mobile/lib/main.dart`
- threat/crypto/recovery references under `implementation/archive/2026-07-26/docs/`
- all release evidence from I22–I24

Do:

1. Freeze the protocol, FFI, storage, linking, recovery, and revocation design for review.
2. Provide the reviewer source revision, threat model, vectors, build instructions, and failure tests.
   Include I15 and I26 transcript derivations; a missing peer-verification path is a review finding.
3. Fix every critical/high finding; record any lower residual risk for the user.
4. Rerun the complete clean release matrix.
5. Only then replace `UnavailableCryptoService`, remove `PM_CRYPTO_UNAVAILABLE`, and make release readiness pass for the implemented path.

Done when: independent findings are closed, release evidence is tied to the commit, and the gate passes without bypasses.

Do not weaken or delete a gate to declare success.
