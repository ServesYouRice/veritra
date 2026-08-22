# T40A — Executable Rust exception expiry

| Field | Contract |
|---|---|
| Consensus source | I40; TEST-11/NTH-13 scope; L18/R3 CI-expiry scope |
| Initial eligibility | Ready immediately after T29; deadline 2026-08-29 |
| Risk | High release control |
| Executor | Balanced+advisor |
| Advisor | Review expiry semantics and release-profile guarantee |
| Depends on | T29 only for mandated sequencing |
| Blocks | T40B-T40D; G27 evidence |
| Parallel safety | One owner for Rust audit script, Cargo profile and CI security job |

## Objective

Make the Rust advisory exception deadline machine-enforced and deterministic,
while pinning release panic/overflow behavior required by the FFI boundary.

## Read first

- `docs/audit-consensus.md` I40 and R3 correction.
- `docs/audits-codex/testing-gaps.md` TEST-11.
- `docs/audits-opus/production-readiness.md` R3 and
  `docs/audits-opus/logical-issues.md` L18.
- `scripts/audit-rust.sh`, `.github/workflows/ci.yml`, `crypto/rust/Cargo.toml`.

## Invariants

- Existing reachability guards and ignored-advisory list remain narrow.
- Date tests use an injectable clock/input; they must not become unfalsifiable
  after the real date passes.
- FFI panic handling and release profile must agree.

## Work

1. Move exception metadata, rationale and expiry into a parseable policy.
2. Fail before/at the agreed boundary according to one documented timezone.
3. Add deterministic before/after-expiry tests.
4. Run the guard in CI and release readiness.
5. Pin `panic` and overflow behavior and verify the FFI test under release mode.

## Acceptance

- An injected expired date fails automatically; a valid date still runs audit.
- CI and release readiness invoke the same guard.
- Release-profile behavior is explicit and tested.

## Required checks

```sh
./scripts/audit-rust.sh
cd crypto/rust && cargo test --release --locked
```

