# Product and Engineering Nice-to-Haves

## Framing

These recommendations are intentionally secondary to the blockers in `production-readiness.md`. They should not displace production MLS integration, sync correctness, data-loss prevention, recovery safety, or release evidence. Each item would materially improve trust, usability, operability, or maintainability after those foundations are secure.

## High-impact nice-to-haves

### NTH-01 - Privacy-safe visible notification policy and controls

- **Severity:** Nice-to-have
- **Location:** Mobile notification UX; Android/iOS native notification integration; settings
- **Description:** Push currently acts primarily as a generic background wake. The product does not provide a complete visible local-notification experience or clear controls for preview level, sound, vibration, per-conversation mute, and lock-screen privacy.
- **Why it matters for production:** A messenger that silently updates only when background execution succeeds can feel unreliable. Conversely, careless previews can violate the product's privacy promise.
- **Recommended fix:** After local decryption, generate notifications on-device according to explicit user policy: no content, sender only, or message preview. Add per-conversation mute, global quiet controls, grouped notifications, tap routing, and reply only if cryptographic/session safety can be maintained. Test locked-device behavior on both platforms.
- **Blocker before production:** No; push status correctness remains separately blocking if push is promised.
- **Related risks or dependencies:** Production crypto; OS background limits; threat model; UI-06 and TEST-05.

### NTH-02 - Guided origin onboarding with QR/deep links

- **Severity:** Nice-to-have
- **Location:** Connect screen, setup page, invite flow
- **Description:** Users must understand and type a server origin, while the current development-oriented localhost default is misleading on phones.
- **Why it matters for production:** Self-hosting already creates onboarding friction. Manual URL entry increases support burden and makes TLS/origin mistakes more likely.
- **Recommended fix:** Let an administrator generate a signed/structured QR or universal link containing only the server origin and invite metadata. Show the verified origin and TLS state before account creation, and require explicit confirmation when switching origins.
- **Blocker before production:** No.
- **Related risks or dependencies:** Deep-link security; invite expiry; origin normalization; UI-08.

### NTH-03 - Operator dashboard for privacy-safe service health

- **Severity:** Nice-to-have
- **Location:** Server admin/operator experience
- **Description:** Operators mainly have configuration, logs, and low-level endpoints; there is no consolidated view of version, storage, backup age, migration state, sync lag, retention backlog, push provider health, and expiring configuration.
- **Why it matters for production:** Self-hosters need to diagnose service health without learning internal schemas or exposing user metadata.
- **Recommended fix:** Add a read-only, strongly authorized operator dashboard or CLI status report with aggregate, non-identifying metrics and links to runbooks. Include exact build digest, schema version, backup freshness, disk headroom, queue ages, and degraded dependencies.
- **Blocker before production:** No; the underlying metrics/alerts in DEP-12 may be blocking for operated GA.
- **Related risks or dependencies:** Admin authorization; metric privacy review; observability implementation.

### NTH-04 - Backup status and guided restore workflow

- **Severity:** Nice-to-have
- **Location:** Operations tooling and admin UX
- **Description:** Backup and restore are command-line operations with no guided verification or status surface for less experienced self-hosters.
- **Why it matters for production:** A transparent last-success/last-drill view and guarded restore flow would reduce operator mistakes and improve trust in self-hosted recovery.
- **Recommended fix:** After hardening the underlying commands, provide a status command/UI, encrypted off-host destination checks, retention preview, restore dry run, manifest comparison, and explicit confirmation of the exact target and rollback artifact.
- **Blocker before production:** No; safe backup/restore and monitored scheduling are blockers independently.
- **Related risks or dependencies:** DEP-04, DEP-05, DEP-09; secret/key recovery policy.

## Product polish

### NTH-05 - Notification and connectivity diagnostics

- **Severity:** Nice-to-have
- **Location:** Settings, push status, connection banner
- **Description:** Users cannot run a safe self-test that distinguishes OS permission, token acquisition, server registration, WebSocket connectivity, provider delivery, and local wake handling.
- **Why it matters for production:** Push/network failures otherwise appear as vague delayed messages and generate difficult support cases.
- **Recommended fix:** Add a privacy-safe “test wake” and diagnostics screen with timestamps, provider state, retry, and help text. Never display or copy raw endpoints, auth secrets, tokens, message IDs, or ciphertext.
- **Blocker before production:** No.
- **Related risks or dependencies:** Provider staging; security review; UI-06.

### NTH-06 - Conversation draft persistence

- **Severity:** Nice-to-have
- **Location:** Chat composer and encrypted local database
- **Description:** Beyond the immediate pre-outbox loss defect, drafts are not a first-class per-conversation encrypted local entity.
- **Why it matters for production:** Users expect unfinished text to survive navigation, interruptions, and process eviction.
- **Recommended fix:** Store drafts encrypted and locally, keyed by account and conversation. Debounce writes, clear only after durable send acceptance, and define retention and multi-device non-synchronization explicitly.
- **Blocker before production:** No; preserving content on send failure is blocking under UI-02.
- **Related risks or dependencies:** Local storage/account scoping; privacy expectations; database migration.

### NTH-07 - Unified account, device, and identity trust center

- **Severity:** Nice-to-have
- **Location:** Profile, device management, encryption identity, recovery settings
- **Description:** Security-sensitive concepts are distributed across placeholder or separate screens without a unified view of the current identity, linked devices, recovery freshness, and verification status.
- **Why it matters for production:** Users need one understandable place to answer “Is this my account, are these my devices, and can I recover safely?”
- **Recommended fix:** Create a trust center showing device names/last activity, identity fingerprint or safety-number verification, recovery backup age, and high-risk actions with reauthentication. Avoid implying server-side verification that the architecture cannot provide.
- **Blocker before production:** No; functional identity/recovery/device controls may be blockers depending on launch scope.
- **Related risks or dependencies:** Production MLS identity model; reauthentication hardening; recovery design.

### NTH-08 - Consistent offline and stale-data affordances

- **Severity:** Nice-to-have
- **Location:** Conversation list, chat, search, devices, communities, settings
- **Description:** Connectivity is surfaced at the shell level, but individual data views do not consistently show when cached data is stale, which actions are queued, or what requires connectivity.
- **Why it matters for production:** Messaging is frequently used across weak networks. Clear local-versus-server state reduces duplicate actions and uncertainty.
- **Recommended fix:** Define shared offline/stale components, last-synced timestamps where useful, queued action badges, and consistent retry behavior. Keep cached content available while clearly marking actions that cannot be completed.
- **Blocker before production:** No.
- **Related risks or dependencies:** Sync/outbox correctness; error taxonomy; UI state components.

### NTH-09 - Localization and locale-aware presentation

- **Severity:** Nice-to-have
- **Location:** Flutter UI strings, dates, counts, accessibility labels
- **Description:** The application is effectively English-only and has no translation workflow.
- **Why it matters for production:** Even before adding languages, centralized copy improves consistency, accessibility review, and locale-correct formatting.
- **Recommended fix:** Adopt Flutter localization generation, define a copy ownership/review process, and test long translations, right-to-left layouts, pluralization, and locale-aware time/size formatting.
- **Blocker before production:** No for an explicitly English-only release.
- **Related risks or dependencies:** UI-12; golden-test matrix.

## Developer experience improvements

### NTH-10 - One canonical release-grade verification command

- **Severity:** Nice-to-have
- **Location:** `scripts/`, CI documentation, contributor workflow
- **Description:** Useful checks are split across lint, tests, race, live contract, native contract, audits, and release-readiness entry points. The ordinary local test command can finish with environment-dependent skips.
- **Why it matters for production:** Contributors need a clear answer to “Does this commit meet the same gate CI and release use?”
- **Recommended fix:** Add a canonical orchestrator that prints prerequisites, executes or explicitly fails required checks, summarizes skips, and emits a machine-readable evidence file. Keep a separate fast inner-loop command.
- **Blocker before production:** No if protected CI enforces the complete set.
- **Related risks or dependencies:** TEST-06 and TEST-09; container caching; developer platform support.

### NTH-11 - Versioned API schema and generated contract fixtures

- **Severity:** Nice-to-have
- **Location:** Go HTTP handlers, Dart API client, API documentation
- **Description:** A large handwritten Dart API client and server handlers share contracts through convention and tests rather than a single versioned schema.
- **Why it matters for production:** Field drift, optionality mismatches, error-shape inconsistencies, and duplicated validation become harder to control as endpoints grow.
- **Recommended fix:** Define a reviewed OpenAPI or equivalent machine-readable schema for non-cryptographic HTTP contracts. Generate models/fixtures selectively while retaining handwritten security-sensitive transport and validation where clearer. Add backward-compatibility checks.
- **Blocker before production:** No.
- **Related risks or dependencies:** API error taxonomy; generated code policy; avoid exposing internal/privacy-sensitive fields.

### NTH-12 - Risk-based coverage and failure-injection tooling

- **Severity:** Nice-to-have
- **Location:** Test infrastructure across Go, Rust, and Flutter
- **Description:** Tests are broad but lack a shared toolkit for pausing async boundaries, injecting storage/network failures, controlling time, and reporting critical-path coverage.
- **Why it matters for production:** The highest-risk bugs found in this audit are interleaving and partial-failure bugs, which are difficult to reproduce without deterministic tools.
- **Recommended fix:** Build reusable fake clocks, controllable transports, failpoint storage adapters, seeded state-machine tests, and per-critical-package coverage reporting. Keep production code free of unsafe test-only behavior through build/test boundaries.
- **Blocker before production:** No, though specific tests in `testing-gaps.md` are blockers.
- **Related risks or dependencies:** Refactoring interfaces around session/sync ownership; CI runtime.

### NTH-13 - Automated dependency freshness and exception expiry

- **Severity:** Nice-to-have
- **Location:** Go, Rust, Dart, Gradle, container base images, advisory policy
- **Description:** Dependency review spans multiple ecosystems, and temporary advisory exceptions require manual tracking.
- **Why it matters for production:** Small teams benefit from automation that raises focused, testable updates without normalizing perpetual warning noise.
- **Recommended fix:** Configure scheduled update PRs grouped by ecosystem/risk, fail on retracted/yanked packages, expire waivers automatically, attach changelog/advisory context, and require the relevant native/mobile regression suites.
- **Blocker before production:** No, except the current crypto advisory/review gate.
- **Related risks or dependencies:** TEST-11; update compatibility; SBOM generation.

## Architecture or stack recommendations

### NTH-14 - Introduce durable background jobs without adding a separate service

- **Severity:** Nice-to-have
- **Location:** Go server post-commit push/realtime work
- **Description:** Some side effects need durability, but the current deployment goal values single-binary simplicity.
- **Why it matters for production:** A SQLite-backed transactional job table can close correctness gaps without prematurely introducing Redis, Kafka, or a second deployable.
- **Recommended fix:** Add a privacy-minimized job/outbox table processed by bounded in-process workers. Use leases, attempts, jittered backoff, expiry, and metrics; preserve idempotency across restart. Reconsider an external queue only after measured single-node limits require it.
- **Blocker before production:** The durable behavior in ARCH-03 is blocking; use of this particular implementation is a recommendation.
- **Related risks or dependencies:** SQLite write contention; push privacy model; worker shutdown.

### NTH-15 - Decompose mobile state along account-scoped ownership boundaries

- **Severity:** Nice-to-have
- **Location:** `mobile/lib/core/app_state.dart`
- **Description:** The global state object has accumulated most product domains and lifecycle responsibilities.
- **Why it matters for production:** Smaller account-scoped services make cancellation, testing, rebuild control, and future feature ownership clearer.
- **Recommended fix:** Refactor incrementally after capturing invariants: first session generation and sync engine, then crypto/outboxes, push/transfers, and feature repositories. Avoid adopting a new state-management package solely for fashion; the ownership model matters more than the library.
- **Blocker before production:** No as a wholesale change; identified lifecycle bugs are blocking.
- **Related risks or dependencies:** ARCH-02; migration test coverage; team familiarity.

### NTH-16 - Keep SQLite and local blobs until measured limits justify adapters

- **Severity:** Nice-to-have
- **Location:** Persistence architecture and future scale planning
- **Description:** It may be tempting to replace SQLite or local blob storage preemptively to look more “production.” Current evidence does not justify that operational complexity.
- **Why it matters for production:** The present single-node product benefits from atomicity and low maintenance. Premature distributed infrastructure would increase failure modes and privacy/operations burden.
- **Recommended fix:** Harden queries, cleanup, backups, projections, and capacity tests first. Define storage interfaces and migration tooling, then consider PostgreSQL/object storage only when tested host profiles or multi-node requirements exceed the current model.
- **Blocker before production:** No.
- **Related risks or dependencies:** PERF-10; deployment roadmap; consistency semantics.

## Future roadmap ideas

### NTH-17 - Local encrypted search with explicit indexing controls

- **Severity:** Nice-to-have
- **Location:** Mobile search and encrypted local storage
- **Description:** A privacy-first messenger can offer richer message search without sending plaintext or broad search metadata to the server.
- **Why it matters for production:** Fast local discovery makes long-lived conversations substantially more useful while preserving the server privacy boundary.
- **Recommended fix:** Build an encrypted/local-only index after decryption, with clear storage cost, rebuild, deletion, retention, and device-lock behavior. Let users disable or clear it. Threat-model leakage from tokenized indexes on a compromised device.
- **Blocker before production:** No.
- **Related risks or dependencies:** Production message decryption; local database performance; retention/deletion semantics.

### NTH-18 - Verification ceremonies for contacts and devices

- **Severity:** Nice-to-have
- **Location:** Conversation details, profile, device link, identity UI
- **Description:** The future product will need an understandable way to verify identities and surface key/device changes.
- **Why it matters for production:** End-to-end encryption is more trustworthy when users can detect unexpected identity changes and verify important contacts out of band.
- **Recommended fix:** Design QR/safety-number verification, device-added/removed notices, verification reset semantics, and clear warnings that do not train users to click through. Bind the UX to the actual MLS identity model and independent crypto review.
- **Blocker before production:** No for a limited preview; recommended for a mature security claim.
- **Related risks or dependencies:** MLS credentials; account recovery; multi-device membership changes.

### NTH-19 - User-facing data export, import, and deletion status

- **Severity:** Nice-to-have
- **Location:** Account settings and recovery/export APIs
- **Description:** Backend account export/deletion capabilities need a safe product workflow with scope explanation, step-up authentication, progress, and completion evidence.
- **Why it matters for production:** Users expect control over their data and need to understand what a ciphertext-oriented server can and cannot export or erase.
- **Recommended fix:** After SEC-02 is resolved, add a scoped export wizard, reauthentication, encrypted archive handling, expiration, and clear category descriptions. For deletion, show irreversible effects, device consequences, pending retention behavior, and a final receipt that reveals no sensitive data.
- **Blocker before production:** No as UI polish; secure authorization/export contents may be blocking.
- **Related risks or dependencies:** SEC-02; legal/privacy policy; backup retention; recovery design.

### NTH-20 - Community moderation and auditable administrative actions

- **Severity:** Nice-to-have
- **Location:** Communities, channels, invitations, blocks, server audit events, admin tooling
- **Description:** As communities grow, operators and community owners will need moderation queues, role visibility, member removal reasons, invite management, and reviewable administrative actions.
- **Why it matters for production:** Abuse handling and transparent governance determine whether a real community deployment remains usable and trustworthy.
- **Recommended fix:** Define least-privilege roles and privacy-minimized audit events, then add invite revocation, membership review, report/block workflows, rate/abuse signals, and operator runbooks. Avoid centralizing message plaintext for moderation; design metadata and user-report mechanisms around the E2EE boundary.
- **Blocker before production:** No for a small trusted-group launch.
- **Related risks or dependencies:** Authorization model; abuse prevention; audit-log retention; E2EE moderation constraints.
