# Architecture Review

## Executive assessment

Veritra has a coherent early architecture for a privacy-first, self-hosted, single-node messenger:

| Layer | Current design | Assessment |
|---|---|---|
| Mobile | Flutter application with encrypted local persistence and native crypto bridge | Productive cross-platform base; session/sync ownership is too centralized and lifecycle-sensitive |
| Cryptography | Rust/OpenMLS exposed through a narrow C ABI | Good language boundary and defensive FFI practices; production integration/review remains deliberately gated |
| Server | Go modular monolith over `net/http` | Appropriate operational simplicity; some post-commit side effects lack durable coordination |
| Persistence | SQLite plus encrypted blob files | Sensible for a small single-node host; read models, cleanup throughput, and recovery atomicity need work |
| Realtime | Durable sync log plus WebSocket wakeups | Correct conceptual split; background mobile processing currently violates the cursor/crypto invariant |
| Operations | Container/Compose/systemd, backup/restore, CI | Strong scaffold; release evidence and recovery automation are not yet production-grade |

The recommended direction is evolutionary rather than a rewrite. Preserve the modular monolith, single-node scope, ciphertext-only server model, and narrow native boundary. Tighten state ownership, add durable work records for side effects, and define explicit operational invariants before considering new infrastructure.

## Architecture strengths

- **Privacy boundary is visible in the design.** The server is structured around ciphertext and generic wakeups, and sensitive client work is intended to remain on-device.
- **Crypto fails closed.** The unavailable production crypto path and release marker prevent an unsafe placeholder from being mistaken for finished encryption.
- **The Go server is divided by domain.** Store and service interfaces make targeted testing and later replacement possible without immediate microservices overhead.
- **Durable sync plus ephemeral wake is the right model.** Correctness can rest on the event log while WebSockets/push only reduce latency.
- **The Rust FFI boundary is defensive.** Length validation, panic containment, ownership rules, and buffer zeroization reduce native failure impact.
- **SQLite matches the stated deployment scope.** A single-node community host benefits from transactional simplicity and low operational burden.
- **Operational basics already exist.** Non-root packaging, health checks, deployment examples, tests, linting, and recovery commands provide a useful base.

## Findings

### ARCH-01 - Two sync processors can own one durable cursor without a shared crypto transaction

- **Severity:** Critical
- **Location:** `mobile/lib/core/app_state.dart`, foreground catch-up; `mobile/lib/push/background_push.dart`, headless catch-up; encrypted local store
- **Description:** Foreground sync applies MLS events and persists resulting crypto/application state with cursor progress. Background wake independently fetches pages and advances the same cursor without the production crypto processor. There is no single account-scoped synchronization owner or durable event inbox mediating both paths.
- **Why it matters for production:** The architecture permits one worker to acknowledge work another worker must perform. That breaks the core invariant: every MLS event must durably update crypto state before its cursor becomes committed.
- **Recommended fix:** Make one account-scoped sync engine the sole owner of event ingestion and cursor advancement. Background execution should invoke that engine or durably append unprocessed events without acknowledging them. Commit inbox event status, MLS state, message projections, and cursor in one serialized transaction or resumable journal.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-01; TEST-01; platform background execution constraints; secure database availability.

### ARCH-02 - `AppState` is a lifecycle, domain, and UI god object

- **Severity:** High
- **Location:** `mobile/lib/core/app_state.dart` (approximately 1,900 lines) and root `AnimatedBuilder` wiring
- **Description:** One notifier owns authentication, session restoration, conversations, messages, sync, WebSocket lifecycle, crypto, outboxes, push, devices, communities, blocks, transfers, calls, and user-visible error state. Async operations rely on mutable global fields and broad notifications.
- **Why it matters for production:** Domain invariants and cancellation ownership are difficult to reason about, tests require large fixtures, unrelated changes rebuild the UI, and stale async work can write into a new session.
- **Recommended fix:** Split by responsibility around an account-scoped session container: authentication/bootstrap, sync engine, conversation repository, crypto/outbox coordinator, push registration, transfer manager, and call coordinator. Give each an explicit lifecycle and narrow observable state. Use session generation/account identity checks at commit boundaries.
- **Blocker before production:** The whole refactor is not a blocker, but lifecycle defects enabled by the current shape (LOG-03 and LOG-04) are blockers.
- **Related risks or dependencies:** PERF-09; test harness redesign; avoid a broad rewrite before invariants are captured.

### ARCH-03 - Post-commit side effects are not durably coordinated

- **Severity:** High
- **Location:** Server message commit followed by recipient lookup, realtime fanout, and push; mobile MLS flush fire-and-forget
- **Description:** Durable message acceptance and downstream wake/control delivery cross a transaction boundary without a durable job/outbox record. A recipient lookup or process failure after commit can suppress fanout, while retry sees an already accepted idempotency key and may not recreate the missing side effect.
- **Why it matters for production:** The source of truth can say work succeeded while clients receive no timely signal. Fire-and-forget client control messages have a similar restart and retry gap.
- **Recommended fix:** Add transactional outbox records containing only privacy-minimized routing/wake data. Process through idempotent bounded workers and mark completion durably. On mobile, persist MLS control work with attempt state and resume it through the account session engine.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-06 and LOG-07; PERF-02; push metadata threat model.

### ARCH-04 - Release policy is encoded as implementation-string absence

- **Severity:** High
- **Location:** `scripts/release-readiness.sh`; release workflow
- **Description:** The most important architectural trust decision—whether production cryptography is acceptable—is represented primarily by grepping for known placeholder markers.
- **Why it matters for production:** Code shape and release evidence are different concerns. A refactor can satisfy the string check without satisfying cryptographic review, interoperability, device packaging, or protocol state-machine verification.
- **Recommended fix:** Define a versioned release policy artifact with required evidence and reviewers. Bind it to the exact commit and artifacts, validate it in protected CI, and keep marker checks only as a supplementary guard.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** DEP-01; SEC-03; governance and reviewer availability.

### ARCH-05 - Read models are computed from event/history tables on hot paths

- **Severity:** Medium
- **Location:** Conversation list/unread/latest-message queries; mobile broad snapshot refresh
- **Description:** The server derives conversation summaries from message history during list reads, and the client often refreshes/persists broad projections after incremental events. The architecture does not clearly separate normalized durable records from efficient query projections.
- **Why it matters for production:** Read cost and client write work increase with history, making the system harder to scale predictably even within a single-node target.
- **Recommended fix:** Introduce explicitly owned projections only where benchmarks justify them: latest-message pointers, unread counters, conversation revision numbers, and incremental client upserts. Update projections transactionally and provide reconciliation commands/tests.
- **Blocker before production:** No for a small private deployment; capacity evidence may make it blocking.
- **Related risks or dependencies:** PERF-01 and PERF-08; migration and repair strategy.

### ARCH-06 - Local encrypted storage identity is not clearly account/origin-scoped

- **Severity:** Medium
- **Location:** Mobile secure local store, database/key naming, session restore and account switch paths
- **Description:** Storage APIs and a global app session make ownership of local database contents, cursors, and keys implicit. The identified stale-write race shows that async work can outlive the account that initiated it.
- **Why it matters for production:** Multi-instance/self-hosted users may connect to different origins or accounts on one device. Ambiguous ownership risks cross-account stale data, accidental clearing, and hard-to-recover key/database mismatches.
- **Recommended fix:** Define a stable account key such as normalized server origin plus immutable account/device identifier. Scope database file, secure key alias, cursor, push subscription, workers, and caches to it. Make session teardown await/cancel all owners before switching.
- **Blocker before production:** Yes if account switching/multiple origins are supported; otherwise explicitly support one local account and enforce it.
- **Related risks or dependencies:** LOG-04; SEC-05; migration of existing local storage.

### ARCH-07 - The call state model is broader than the intended call product

- **Severity:** High
- **Location:** Server call store/service authorization and conversation membership model
- **Description:** Call transitions are authorized by conversation membership, without consistently constraining the call to a direct conversation or fixed participant set. Any current member of a larger conversation can potentially act on shared call state.
- **Why it matters for production:** Signaling authorization must match who is invited, who may answer, and how membership changes affect an active call. A generic conversation-member rule can disclose state or permit unauthorized transitions.
- **Recommended fix:** Define a call aggregate with explicit initiator, invited device/account participants, conversation type, lifecycle transition table, membership snapshot/version, expiry, and per-transition authorization. Reject unsupported group calls until their semantics are designed and tested.
- **Blocker before production:** Yes before enabling calls.
- **Related risks or dependencies:** LOG-10; WebRTC identity binding; device-level ringing; group-call roadmap.

### ARCH-08 - There is no explicit architecture capacity contract

- **Severity:** Medium
- **Location:** Architecture and operations documentation; configuration defaults
- **Description:** “Single node” is documented, but tested limits and degradation behavior are not. The 10,000 socket cap, retention batch limits, attachment size, and SQLite settings exist as isolated constants rather than a coherent supported profile.
- **Why it matters for production:** Operators need to know whether a deployment is within the design envelope and which metric requires migration or sharding. Without this, architecture decisions cannot be evaluated against product needs.
- **Recommended fix:** Publish small/medium host profiles backed by load tests, including accounts, concurrent devices, daily messages, retention, storage, attachment throughput, backup/RTO, and expected latency. State the point at which a managed database, object storage, queue, or multi-node design should be evaluated.
- **Blocker before production:** Yes before making reliability or scale claims; not for a scoped private alpha.
- **Related risks or dependencies:** PERF-10; deployment metrics; roadmap discipline.

## Recommended target shape

```text
Flutter UI
  -> account-scoped session container
       -> sync engine (single cursor owner)
            -> durable event inbox
            -> MLS state + message projections (atomic commit)
       -> durable message/MLS outboxes
       -> push, transfer, and call coordinators

Go modular monolith
  -> domain services + SQLite transactions
       -> durable sync log
       -> privacy-minimized transactional job outbox
            -> bounded realtime/push workers
  -> encrypted blob storage
```

This shape does not require microservices, Kafka, or a database rewrite. The immediate value comes from explicit ownership and durable transaction boundaries.

## Recommended architecture work order

1. Establish the single sync/cursor/MLS invariant and regression tests (ARCH-01).
2. Make downstream fanout and MLS control work durable and idempotent (ARCH-03).
3. Correct account/session ownership and call authorization (ARCH-06 and ARCH-07).
4. Replace the release marker with evidence-bound policy (ARCH-04).
5. Split `AppState` incrementally along those tested ownership boundaries (ARCH-02).
6. Add read projections only where benchmarks require them (ARCH-05).
7. Publish and monitor a tested single-node capacity contract (ARCH-08).
