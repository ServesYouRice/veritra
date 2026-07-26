# Nice-to-Haves and Product Roadmap

**Audit date:** 2026-07-21

These items are optional enhancements. They do **not** replace the blockers in `production-readiness.md`. Product analytics/telemetry is intentionally not recommended because repository policy forbids it; operator-owned aggregate observability is the compatible alternative.

## High-impact nice-to-haves

### NICE-01 — Member-safe account recovery

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Recovery/account lifecycle; only offline owner password reset exists |
| Blocker before production | No |

**Description:** Non-owner users who lose all linked devices have no practical password/account recovery path.  
**Why it matters:** Permanent lockout creates support burden and surprises users.  
**Recommended fix:** Design recovery around a user-held recovery secret or verified device transfer, with clear loss semantics; password recovery must never imply message-key recovery.  
**Risks/dependencies:** High security/design dependency on production crypto and encrypted backup; avoid admin escrow or silent access.

### NICE-02 — Client-encrypted backup and restore UX

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Mobile settings; server backup-blob APIs; `docs/recovery.md` |
| Blocker before production | No for initial messaging, but important for user trust |

**Description:** Server blob endpoints exist, but users cannot create, verify, download, or restore an encrypted personal backup.  
**Why it matters:** Device loss can mean permanent history/key loss.  
**Recommended fix:** Add recovery-key creation, authenticated manifest, progress, periodic verification, rollback counter, restore preview, and multi-device recovery UX.  
**Risks/dependencies:** Never send the recovery key to the server; requires independent cryptographic review and secure local database export.

### NICE-03 — Local encrypted message search

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Mobile search; `docs/search.md` |
| Blocker before production | No |

**Description:** Search is metadata-only even after messages eventually decrypt locally.  
**Why it matters:** Long-lived messengers need usable local history retrieval.  
**Recommended fix:** Build an encrypted on-device index keyed by the local database key, with rebuild/delete controls and no server sync by default.  
**Risks/dependencies:** Depends on decrypted local storage, deletion/retention semantics, resource limits, and background indexing privacy.

### NICE-04 — Role-gated operator/admin console

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Admin APIs; no mobile/web admin surface |
| Blocker before production | No for a CLI-operated pilot |

**Description:** Account status, invite revocation, storage usage, and audit-event APIs are not exposed in a usable console.  
**Why it matters:** Self-hosters otherwise need custom API calls for routine abuse and account operations.  
**Recommended fix:** Add a minimal role-gated console showing metadata only, with recent-auth confirmation and explicit audit records.  
**Risks/dependencies:** Must never expose ciphertext/content, push endpoints, secrets, or silent private-content access.

## Product polish

### NICE-05 — Guided first-run and instance onboarding

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | `/setup`, mobile connect/register, deployment docs |
| Blocker before production | No after safe setup is functional |

**Description:** Operators and users must translate documentation into connection, setup, invite, device-link, and security steps.  
**Why it matters:** Setup mistakes are costly in a self-hosted security product.  
**Recommended fix:** Add a fail-closed readiness checklist, QR instance configuration, TLS/fingerprint explanation, and progressive onboarding that states what the server can and cannot see.  
**Risks/dependencies:** Browser setup cannot handle private keys until a reviewed browser crypto design exists.

### NICE-06 — Privacy-conscious profiles and conversation identity

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Profile/chat list/community UI |
| Blocker before production | No; unambiguous DM identity itself is a blocker elsewhere |

**Description:** The profile is mostly IDs/role and has no user-controlled display name/avatar/about model.  
**Why it matters:** Stable visual identity improves confidence in groups and communities.  
**Recommended fix:** Add optional, scoped profile attributes with clear visibility and local caching; consider generated avatars before server-hosted images.  
**Risks/dependencies:** Profile metadata is not E2EE message content and increases social-graph/identity exposure; document retention and export/delete behavior.

### NICE-07 — Presence-free interaction feedback

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Chat UI; typing/read-receipt routes |
| Blocker before production | No |

**Description:** Typing and receipt infrastructure has no polished user controls or visibility.  
**Why it matters:** Feedback improves conversational confidence without requiring invasive online-presence tracking.  
**Recommended fix:** Add opt-in read-receipt controls, ephemeral typing indicators, delivered/synced states, and privacy explanations.  
**Risks/dependencies:** Never build persistent presence analytics; honor blocks/mutes and minimize retained metadata.

### NICE-08 — Conversation organization

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Chat list and conversation preferences |
| Blocker before production | No |

**Description:** There is no archive, pin, mark unread, or local draft affordance.  
**Why it matters:** These small controls materially improve daily use as conversation count grows.  
**Recommended fix:** Start with local pin/archive/drafts; sync only when the privacy and multi-device semantics are explicit.  
**Risks/dependencies:** Draft plaintext must be encrypted locally and excluded from server/log/push paths.

## Developer experience improvements

### NICE-09 — Machine-readable API contract and generated compatibility checks

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | `docs/api.md`; Go handlers; Dart `ApiClient` |
| Blocker before production | No, though contract tests are required |

**Description:** The API is documented manually and models are duplicated across Go/Dart.  
**Why it matters:** Drift makes feature work slower and integration failures more likely.  
**Recommended fix:** Add a reviewed OpenAPI/JSON-schema source for metadata/ciphertext envelopes and generate or validate models/fixtures in CI.  
**Risks/dependencies:** Schema tooling must not introduce plaintext message fields or weaken custom validation.

### NICE-10 — Privacy-safe integration fixture toolkit

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Test helpers across server/mobile/crypto |
| Blocker before production | No |

**Description:** Each layer hand-builds opaque values and fake clients independently.  
**Why it matters:** A shared synthetic fixture toolkit would make multi-device, proxy, backup, and migration regressions easier to reproduce.  
**Recommended fix:** Provide generators for accounts/devices/opaque ciphertext/key-package-shaped bytes and ephemeral instances.  
**Risks/dependencies:** Fixtures must be unmistakably synthetic and never normalize plaintext server storage.

### NICE-11 — Faster scoped verification commands

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | `scripts/test.*`, `scripts/lint.*`, CI |
| Blocker before production | No |

**Description:** The all-in-one scripts stop at the first stack failure and repeatedly download container dependencies.  
**Why it matters:** Slow feedback encourages partial local verification.  
**Recommended fix:** Add documented scoped commands (`test:server`, `test:crypto`, `test:mobile`, contract/e2e) plus cache-aware aggregate reporting that still exits nonzero if any phase fails.  
**Risks/dependencies:** Keep pinned images/lockfiles and ensure the canonical full gate remains simple.

### NICE-12 — Versioned protocol/release compatibility matrix

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Release notes; server/client protocol markers |
| Blocker before production | No |

**Description:** There is no concise matrix of server, client, database, crypto protocol, and backup-format compatibility.  
**Why it matters:** Self-hosters need to know upgrade order and rollback limits.  
**Recommended fix:** Publish a versioned compatibility table and automate checks against manifest metadata.  
**Risks/dependencies:** Avoid implicit downgrade/fallback for cryptographic protocols.

## Architecture or stack recommendations

### NICE-13 — Keep the modular monolith/SQLite until measured triggers are exceeded

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Server architecture and deployment ADRs |
| Blocker before production | No |

**Description:** The current architecture is appropriate for a small self-hosted v1, but future-stack suggestions are not tied to measured triggers.  
**Why it matters:** Premature Postgres/object-storage/message-bus adoption adds operational and privacy complexity.  
**Recommended fix:** Publish thresholds for write contention, database/blob size, realtime connections, backup duration, and availability needs; externalize storage/fan-out only when evidence crosses them.  
**Risks/dependencies:** Preserve interfaces and ciphertext-only boundaries so later adapters remain possible.

### NICE-14 — Use durable background-work primitives before adding more integrations

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Push fan-out, blob cleanup, future mail/provider tasks |
| Blocker before production | No |

**Description:** Best-effort goroutines and log-only cleanup are adequate for a prototype but will multiply as features grow.  
**Why it matters:** A small DB-backed work queue can make retries, shutdown, and observability consistent without a new service.  
**Recommended fix:** Define a bounded SQLite outbox/job table with idempotent handlers for non-message background work; keep message durability on its existing transactional path.  
**Risks/dependencies:** Do not store push endpoint secrets in logs/job diagnostics; prevent queue work from starving primary SQLite writes.

## Future roadmap ideas

### NICE-15 — Passkeys as an optional authentication path

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Authentication roadmap/threat model |
| Blocker before production | No |

**Description:** Authentication is password plus device secret; passkeys are deferred.  
**Why it matters:** Passkeys can reduce phishing and password-recovery burden.  
**Recommended fix:** Add WebAuthn/passkeys as optional device-bound authentication after the current linking/recovery model is stable.  
**Risks/dependencies:** Passkeys authenticate access; they do not replace MLS keys or recover encrypted history.

### NICE-16 — Calls/media only after a separate E2EE design review

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Call signaling scaffold; `docs/calls.md` |
| Blocker before production | No; keep disabled |

**Description:** The server has bounded encrypted signaling scaffolding, but no production media path.  
**Why it matters:** Calls are valuable, but they substantially expand metadata, NAT, abuse, bandwidth, and E2EE scope.  
**Recommended fix:** Start with reviewed 1:1 media architecture, explicitly document E2EE/SFU trust, and gate the feature behind platform/network tests.  
**Risks/dependencies:** Do not market current signaling as production calling.

### NICE-17 — Desktop client after mobile protocol stability

| Field | Detail |
| --- | --- |
| Severity | Nice-to-have |
| Location | Product roadmap |
| Blocker before production | No |

**Description:** Only Android/iOS are targeted.  
**Why it matters:** Desktop use is common for messaging and can improve accessibility/productivity.  
**Recommended fix:** Reuse the reviewed protocol and device-link model only after mobile state/backup interoperability is stable.  
**Risks/dependencies:** Desktop secure storage and local database threat models need their own review; avoid a browser client that weakens key custody.

