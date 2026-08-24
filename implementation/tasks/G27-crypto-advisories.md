# G27 — Coordinated OpenMLS/HPKE advisory closure

| Field | Contract |
|---|---|
| Consensus source | I27; SEC-03 advisory scope; R3 exception scope |
| Routing snapshot (board wins) | Upstream/review blocked |
| Risk | Release blocker |
| Executor | Strong |
| Advisor | Required before selecting any RC, Git dependency or private fork |
| Depends on | Coordinated stable upstream release or explicit approved exception review |
| Blocks | G25 |
| Parallel safety | Upstream research is read-only; lockfile/native changes have one owner |

## Objective

Resolve the guarded RustSec advisories through a coordinated reviewed
OpenMLS/HPKE release, or explicitly re-review the narrow exception before its
deadline while production remains fail-closed.

## Read first

- `docs/board.md` I27.
- `docs/audit-consensus.md` I27 and reconciled source IDs SEC-03/R3.
- `scripts/audit-rust.sh`, `crypto/rust/Cargo.toml`, `Cargo.lock`, MLS suite pin.

## Invariants

- Do not adopt a release candidate, unreleased Git dependency or private crypto
  fork without explicit approval and independent review.
- Do not broaden ignored advisories or remove reachability guards.

## Work

1. Recheck coordinated stable upstream versions and advisory status.
2. If stable fixes exist, update the whole compatible graph and notices/SBOM.
3. Rerun vectors, Rust tests, audits, ABI and Android/iOS native builds.
4. If no stable fix exists by the deadline, document current reachability and
   obtain explicit re-approval; keep the release blocked.

## Acceptance

- Guarded advisories are resolved in a stable reviewed graph, or a current
  explicit exception blocks release and has a new executable expiry.
- Lockfile, notices, SBOM, vectors and native builds agree.

## Required checks

```sh
./scripts/audit-rust.sh
./scripts/verify-mobile-crypto.sh
```
