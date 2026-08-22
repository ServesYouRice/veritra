# Veritra Production Audit Plan

## Audit charter

This is a production-readiness audit of the current working tree as observed on 2026-08-08. It is evidence gathering only: no application, test, deployment, or dependency files will be modified. Audit artifacts are the only intended changes.

The working tree contains substantial pre-existing changes, including the active K2 / Bone Flutter redesign. Findings will describe the current files as they exist and will not attribute those changes to this audit. Existing audits and archived audit material are excluded from the evidence set to keep this review independent.

## Product and stack map

| Area | Current implementation | Audit focus |
| --- | --- | --- |
| Product | Self-hosted, privacy-first mobile messenger | Trust, onboarding, operability, honest release state |
| Mobile | Flutter/Dart for Android and iOS | Navigation, responsive/accessibility behavior, state lifecycle, offline/sync UX |
| Local data | Drift + SQLite3MC, key material in platform secure storage | Fail-closed behavior, transactions, migration/recovery, data loss risks |
| Server | Go modular monolith, `net/http`, single-node SQLite | Authentication/authorization, consistency, concurrency, limits, shutdown |
| Crypto | Rust/OpenMLS behind a versioned C ABI | Boundary safety, state rollback protection, release gating, review evidence |
| Realtime | WebSocket plus durable sync-event polling | Reconnects, cursor correctness, event loss/duplication, backpressure |
| Media/features | Encrypted attachments, native push, WebRTC/TURN calls | Secret handling, metadata leakage, lifecycle cleanup, partial failure |
| Deployment | Scratch container, Docker Compose/Caddy, systemd | Secure defaults, upgrades, backup/restore, supply chain, rollback |
| CI/release | GitHub Actions for Go/Rust/Flutter, vulnerability and license checks | Reproducibility, platform coverage, release artifact completeness |

## Core user and operator flows

1. A self-hoster deploys the server, configures TLS/secrets, checks readiness, and performs first-owner setup.
2. A user connects to an instance, signs in or joins with an invite, and enrolls a cryptographic device identity.
3. An existing user links, approves, reviews, and revokes devices.
4. A user browses DMs/groups/communities, creates a conversation, opens a thread, and searches metadata.
5. A device encrypts locally, queues/sends an envelope, receives acknowledgements, catches up through WebSocket/durable sync, decrypts locally, and advances protected state.
6. Users manage members, mute/block accounts, read state, disappearing-message settings, edits/deletes/reactions, and account/profile settings.
7. Users upload/download encrypted attachments, register for generic push, and initiate/receive calls through operator-provided TURN.
8. Users create/restore encrypted backups, export/delete an account, recover from offline periods, and handle expired or revoked credentials.
9. Operators monitor health/metrics/logs, rotate secrets, back up off-host, upgrade, roll back, restore, and respond to abuse or incidents.

Production messaging is intentionally unavailable in the current tree: `UnavailableCryptoService` and `PM_CRYPTO_UNAVAILABLE` are explicit fail-closed release gates. The audit will treat removing those gates prematurely as unsafe and the incomplete production path as a launch blocker, not as an implementation defect to bypass.

## Review plan

### 1. Baseline and evidence integrity

- Record repository structure, current worktree state, authoritative documentation, dependency manifests, and deployment/release configuration.
- Run the project-provided test, lint, and release-readiness checks where the environment permits.
- Separate verified behavior from documentation claims and clearly mark checks that require credentials, hardware, macOS, or external review.

### 2. UI and UX

- Inspect all Flutter screens, shared widgets, navigation, forms, dialogs, error/loading/empty states, and destructive actions.
- Exercise the runnable setup web surface and any locally runnable Flutter surface.
- Check compact phone, large phone, tablet/landscape, dark mode, large text, reduced motion, keyboard/focus, and screen-reader semantics where tooling permits.
- Trace each visible action to a real state mutation or explicitly gated behavior.

### 3. Logic and data integrity

- Trace authentication, enrollment, session invalidation, conversation membership, messaging, sync, retries, pagination, and account deletion.
- Review async cancellation, lifecycle cleanup, idempotency, transaction boundaries, conflict handling, and storage migrations.
- Check client/server model and API-contract alignment, including malformed, duplicated, stale, and out-of-order input.

### 4. Security and privacy

- Verify authorization at every object subroute and role boundary.
- Review password/token handling, rate limits, proxy identity, WebSocket authentication, upload/download controls, and secret/log redaction.
- Review crypto FFI ownership/zeroization/error handling and fail-closed wiring without claiming cryptographic assurance beyond available evidence.
- Check supply-chain controls, mobile platform permissions, backup/recovery exposure, and metadata minimization.

### 5. Performance and resilience

- Inspect SQL query shape/index coverage, pagination, transaction duration, file streaming, queues, retention jobs, reconnect loops, and UI rebuild patterns.
- Evaluate boundedness under large accounts, long threads, slow clients, network loss, disk pressure, and process restart.
- Check health/readiness semantics, graceful shutdown, backup consistency, and recovery behavior.

### 6. Testing, architecture, and deployment

- Map tests to critical flows and identify missing unit, integration, adversarial, visual, accessibility, migration, recovery, and real-device coverage.
- Assess module boundaries, generated code, duplication, complexity hotspots, observability, and operational documentation.
- Review CI/release gates, artifacts, signing, provenance, SBOM, container/service hardening, configuration drift, and rollback prerequisites.

## Severity and blocker rules

| Severity | Meaning |
| --- | --- |
| Critical | Credible path to severe compromise, unrecoverable loss, or fundamentally unsafe launch behavior |
| High | Likely production failure, security/privacy breach, or core-flow failure under realistic conditions |
| Medium | Material reliability, usability, operability, or maintainability problem with a practical workaround |
| Low | Limited-impact defect or localized production polish gap |
| Nice-to-have | Optional improvement that increases product completeness or engineering leverage |

An item is a production blocker when it prevents safe completion of a core flow, violates a documented privacy/security invariant, lacks required release evidence for a high-risk boundary, or makes recovery from a foreseeable failure unreliable. Blocker status is independent of severity labels and will be stated explicitly on every finding.

## Planned deliverables

- `ui-issues.md`
- `logical-issues.md`
- `security-issues.md`
- `performance-issues.md`
- `testing-gaps.md`
- `deployment-risks.md`
- `architecture-review.md`
- `production-readiness.md`
- `nice-to-haves.md`

Each finding will include severity, precise location, production impact, recommended fix, blocker status, and related risks/dependencies. Final priorities will be deduplicated across files and ordered by launch impact.
