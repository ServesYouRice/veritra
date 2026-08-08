# Production Readiness Decision

## Decision: NO-GO

The current working tree is not safe or functionally complete for a production launch. The existing fail-closed crypto gates are correct and must remain in place. Removing only `UnavailableCryptoService` and `PM_CRYPTO_UNAVAILABLE` would expose additional Critical/High state, durability, notification, release, and recovery defects documented in this audit.

## Launch gate matrix

| Gate | Current state | Decision |
| --- | --- | --- |
| Production MLS wired and independently reviewed | Intentionally unavailable; external review not complete | Blocked |
| Recovery capability secrecy | Fake capability reproduced verbatim in server request logs | Blocked |
| Foreground/background crypto-state consistency | Background wake advances cursor without MLS processing | Blocked |
| Offline message durability | Oldest unsent envelope is silently evicted after 100 entries | Blocked |
| Session/account isolation | Bootstrap and teardown can race in-flight state writers | Blocked |
| Retention promise | Cleanup capacity is only 500 rows per class every six hours | Blocked |
| Push reliability | FCM-only registration is broken; fan-out is not durable | Blocked |
| Stale-device recovery | MLS cursor expiry has no recovery UX/protocol | Blocked |
| Sensitive account operations | Export lacks recent auth and includes reusable push authentication material | Blocked |
| Device key-loss recovery | Secure-storage reset can orphan the encrypted local database without a recovery state | Blocked |
| Backup and restore safety | Fixed staging paths and non-journaled activation are not fault-tolerant | Blocked |
| Operational recovery | Backups are manual and no monitored RPO/RTO or restore drill is enforced | Blocked |
| Mobile release evidence | Signed Android/iOS candidates and physical-device matrix are pending | Blocked |
| Release governance | Tag workflow can publish after a two-string gate without depending on CI/review evidence | Blocked |
| Automated baseline | Unit/widget tests, lint, analyzer, and Go race detector pass | Pass, insufficient alone |
| Runtime server baseline | Isolated production server became healthy with required setup token; security headers present | Pass |

## Highest-priority fix order

1. **Preserve the fail-closed release state.** Do not enable messaging or publish a production tag while the remaining gates are open.
2. **Stop capability leakage.** Move recovery credentials out of URLs, use matched route patterns for logs, rotate exposed capabilities, and verify proxy/application logs with sentinel tests.
3. **Unify crypto event ownership.** Prevent background tasks from advancing the cursor without atomic MLS processing; implement stale-device recovery.
4. **Guarantee client durability and isolation.** Remove outbox eviction, serialize bootstrap/logout/account changes, and add session-generation cancellation.
5. **Make security-critical delivery durable.** Build retryable MLS and server notification outboxes; fix FCM-only registration.
6. **Honor retention at supported load.** Drain cleanup backlogs, add indexes/metrics, and prove retention under sustained traffic.
7. **Harden sensitive APIs and future calls.** Require recent auth for export/reauth controls and enforce actor-specific call state.
8. **Make recovery operationally safe.** Harden backup/restore staging and activation, automate off-host backups, and prove restore/RPO/RTO through fault-injected drills.
9. **Repair release engineering.** Make release depend on CI plus immutable review evidence; publish signed mobile artifacts built from the reviewed native crypto revision.
10. **Complete product validation on one immutable commit.** Enable only reviewed crypto-backed screens, correct status messaging, and run dependency, live/native contract, signed-device, push/TURN, offline/restart/revocation, load, accessibility, backup/restore, and independent retest evidence.

## Verification performed for this audit

| Check | Result | Notes |
| --- | --- | --- |
| `scripts/test.ps1` | Pass | Go packages, 17 Rust tests, 79 Flutter tests; 2 environment checks skipped |
| `scripts/lint.ps1` | Pass | `gofmt`, `go vet`, Rust fmt/clippy, Flutter analyze, and Dart format check |
| `go test -race ./...` in pinned Go container | Pass | No race detector findings in existing server tests |
| `scripts/release-readiness.sh` | Expected failure | `release blocked: production MLS crypto is not wired` |
| Isolated production container | Pass with required token | `/healthz` and setup status returned 200 |
| Recovery-log sentinel request | Fail | Fake token appeared verbatim in `http_request.route` |
| Setup security headers | Pass | CSP, frame denial, no-referrer, nosniff, COOP/CORP, permissions policy |
| In-app visual browser pass | Not available | No browser backend was attached; static source/runtime HTTP and Flutter widget evidence were used |

The green automated checks are useful but do not exercise the newly identified failure interleavings, signed mobile binaries, real push/TURN providers, or physical-device crypto behavior.

## Conditions for changing to GO

- [ ] Every blocker in `ui-issues.md`, `logical-issues.md`, `security-issues.md`, `performance-issues.md`, `testing-gaps.md`, `deployment-risks.md`, and `architecture-review.md` is fixed or explicitly rejected by an accountable security/product owner with documented residual risk.
- [ ] Independent security review is complete against the exact release commit and all Critical/High findings are independently retested.
- [ ] The guarded Rust advisory exceptions are either removed by a coordinated stable upgrade or re-approved with current reachability evidence before their deadline.
- [ ] Signed Android and iOS artifacts install and pass the physical-device matrix, including background push, network changes, offline catch-up, revocation, backup restore, and accessibility.
- [ ] Release automation cryptographically binds tests, review evidence, source revision, SBOM, provenance, checksums, server image, and mobile artifacts.
- [ ] A restore drill and sustained-load/retention test pass with recorded RPO/RTO and supported capacity.

## Positive readiness signals

The project already has several strong foundations worth preserving: fail-closed crypto wiring, encrypted local storage, transactional message/sync persistence, strict JSON and size limits on most APIs, single-writer SQLite/WAL configuration, non-root scratch containers, proxy-aware rate limiting, generic push payloads, SSRF-resistant WebPush dialing, backup integrity manifests, graceful server shutdown, pinned CI actions/toolchains, SBOM/provenance support, and unusually candid release documentation. The no-go decision comes from concrete gaps around those foundations, not from an absence of sound engineering intent.
