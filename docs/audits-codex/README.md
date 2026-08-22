# Veritra Production Audit

> Source audit snapshot. It is evidence, not the implementation backlog.
> Decisions and corrected severities live in
> [`../audit-consensus.md`](../audit-consensus.md).

## Outcome

**Production decision: NO-GO.** The project has a strong engineering baseline and correctly fails closed while production MLS is unavailable, but it is not yet safe or functionally complete for launch. The most serious blockers are:

1. Background push catch-up can advance the shared sync cursor without processing MLS events.
2. The mobile outbox silently evicts the oldest unsent message after 100 entries.
3. Recovery capability tokens are written verbatim to request logs.
4. Session bootstrap/logout can race in-flight work and cross account boundaries.
5. MLS control delivery and server notification fanout are not durably retried.
6. Retention cleanup cannot converge under modest sustained traffic.
7. Sensitive export/reauth, stale-device recovery, and call authorization need hardening.
8. Backup/restore activation, scheduling, and recovery evidence are not production-grade.
9. Release publication is not bound to full CI, independent crypto review, and signed mobile artifacts.
10. Real-device, provider, accessibility, load, and recovery matrices remain incomplete.

Do not remove the current production crypto gates merely to make the readiness script pass.

## Audit basis

- **Observed:** 2026-08-08
- **Branch/base:** `main` at `d60e45b643702ff8420161e3f9e78429df7595e8`, plus substantial pre-existing uncommitted product/design changes
- **Scope:** Flutter mobile, Go server, Rust/OpenMLS boundary, SQLite/blob persistence, CI/release, container/systemd deployment, backup/restore, security, performance, and product readiness
- **Change policy:** This audit changed only files in `audits-codex/`; it did not modify production, test, dependency, or deployment code
- **Independence:** Existing archived audits were excluded from the review evidence set

The reports contain 76 issue records across UI, logic, security, performance, testing, deployment, and architecture, plus 20 product/engineering nice-to-haves. Related findings deliberately cross-reference the same root risk from different review dimensions.

## Read in this order

1. [Audit plan](audit-plan.md) - stack, user flows, method, severity, and evidence plan
2. [Production readiness](production-readiness.md) - no-go decision, launch gates, fix order, and verification performed
3. [Logical issues](logical-issues.md) - correctness, state, durability, sync, retention, and integration failures
4. [Security issues](security-issues.md) - capabilities, sensitive APIs, crypto gate, authentication, logging, and hostile-server boundaries
5. [UI issues](ui-issues.md) - core product completeness, accessibility, responsive behavior, states, forms, and priorities
6. [Deployment risks](deployment-risks.md) - release artifacts, recovery tooling, backups, migrations, secrets, and operations
7. [Testing gaps](testing-gaps.md) - missing interleaving, device, provider, load, fault-injection, and supply-chain evidence
8. [Performance issues](performance-issues.md) - query growth, fanout, sync amplification, retention throughput, and capacity
9. [Architecture review](architecture-review.md) - strengths, root design risks, and evolutionary target shape
10. [Nice-to-haves](nice-to-haves.md) - high-impact product additions, polish, developer experience, architecture guidance, and roadmap

## Verification summary

| Evidence | Result |
|---|---|
| Project test suite | Passed Go, 17 Rust tests, and 79 Flutter tests; 2 environment-dependent checks skipped |
| Project lint/static checks | Passed Go formatting/vet, Rust fmt/Clippy, Flutter analysis, and Dart formatting |
| Go race detector | Passed all exercised server packages |
| Release-readiness script | Correctly failed because production MLS is not wired |
| Isolated server smoke | Health and setup endpoints passed; setup security headers were present |
| Recovery-token log sentinel | Failed: the fake token appeared verbatim in the request log route |
| Interactive browser/device audit | Not available in this environment; retained as an explicit verification gap |

## Immediate fix sequence

- [ ] Preserve the no-go crypto/release gate.
- [ ] Eliminate recovery capability leakage and rotate any potentially exposed capabilities.
- [ ] Unify background/foreground event processing under an atomic MLS-state/cursor invariant.
- [ ] Prevent outbox data loss and session/account stale writes.
- [ ] Add durable retry for MLS and server notification side effects.
- [ ] Make retention converge and instrument backlog.
- [ ] Harden export/reauth, device recovery, and call state authorization.
- [ ] Make backup/restore fault-safe and automate monitored off-host recovery.
- [ ] Bind release to protected CI/review evidence and signed mobile artifacts.
- [ ] Retest one immutable candidate across real devices, providers, accessibility, load, upgrade, and restore.
