# Veritra deep audit

> Remediation is tracked in [status.md](status.md). Historical evidence below remains unchanged for traceability.

- **Audit date:** 2026-07-11
- **Project:** Veritra / Private Messenger
- **Audited commit:** `eb52fc43be9a7362904a5169b6b84230d7866cef`
- **Verdict:** **Do not deploy outside an isolated development environment.**

The project has a promising ciphertext-first server foundation, but it is not a usable or safe production messenger yet. The highest-risk problems are an unauthenticated first-run ownership race, absent production cryptography, missing Android/iOS projects, broken client/server contracts, non-atomic delivery state, and unsafe recovery/deployment paths.

## Finding count

| Severity | Count | Meaning |
|---|---:|---|
| Critical | 7 | Direct takeover, privacy-boundary, or release-stopping failure |
| High | 44 | Likely security, correctness, data-loss, or major product failure |
| Medium | 24 | Material reliability, operability, UX, or maintainability risk |
| **Total** | **75** | Each finding is counted once |

This count intentionally excludes vague wishlist items and findings from `audits-fable` that are no longer true.

## Audit map

- [01-release-gates.md](01-release-gates.md) — the 14 issues that should block any production release.
- [02-security-and-correctness.md](02-security-and-correctness.md) — authorization, identity, privacy, protocol, and data-integrity findings.
- [03-mobile-ui-and-sync.md](03-mobile-ui-and-sync.md) — Flutter, sync, navigation, accessibility, and client lifecycle findings.
- [04-operations-performance-and-testing.md](04-operations-performance-and-testing.md) — deployment, backup, observability, performance, architecture, supply chain, and test gaps.

## Recommended fix order

1. Close first-run setup takeover and owner-recovery holes.
2. Define and implement the production cryptographic protocol, key lifecycle, device proof, decryption, and recovery model.
3. Restore a reproducible mobile build: supported Flutter version, Android/iOS projects, signing, secure-storage configuration, and platform CI.
4. Fix channel creation, message/idempotency transactions, sync pagination/acknowledgement, and membership event delivery.
5. Make deletion, exports, retention, attachments, backups, reactions, push, and calls match their UI/API promises.
6. Harden restore, container storage ownership, systemd exposure, quotas, health checks, and release/supply-chain controls.
7. Split the large HTTP/storage/client state modules only after the critical invariants have tests.

## Verification status

- Static review covered all tracked source, migrations, deployment files, workflows, root documentation, and the prior `audits-fable` reports.
- `go`, `cargo`, and `flutter` are not installed in the audit environment.
- Docker client `28.4.0` is installed, but the Docker Desktop Linux daemon is unavailable.
- `./scripts/test.ps1` and `./scripts/lint.ps1` both stop at the first Docker invocation with a missing `dockerDesktopLinuxEngine` pipe. **No test, lint, build, migration, Compose, or screenshot pass is claimed.**
- The shared worktree also contains an unrelated modification to `mobile/pubspec.lock`. The committed lock requires Flutter `>=3.38.4`; the modified file was regenerated for Flutter `>=3.24.0`. The report preserves that change and evaluates both states where relevant.
- UI screenshots were not taken: there is no runnable mobile target or Flutter toolchain, and this audit makes no UI code changes.

## Revalidated prior-audit status

Still current from `audits-fable`: production crypto is a stub, role demotion is possible, typing lacks membership authorization, blob quotas are absent, sync is incomplete, and several product surfaces are write-only.

No longer current: trusted-proxy configuration is now present in Compose; timestamps use a fixed sortable format; account search is exact rather than substring enumeration; logout/device revocation exists; expired messages are pruned; attachment write rollback exists; and the old trailing-JSON decoder issue is fixed.

## Strengths worth preserving

- Message bodies and attachment contents are designed as ciphertext-only server data.
- Session tokens are stored as hashes; password verification includes a dummy bcrypt path.
- Migrations are checksummed.
- Message expiry is enforced in reads and by a sweeper.
- Push payload policy is generic and has a focused privacy test.
- Compose now binds direct HTTP to loopback and declares its trusted proxy network.
- Metadata account search avoids broad directory enumeration.

These are useful foundations, but they do not offset the release gates.
