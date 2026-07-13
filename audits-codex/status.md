# Remediation status

Updated: 2026-07-13

Testing-gap work remains excluded by request. Historical finding text is preserved in the numbered audit files.

Legend: **Closed** = implemented; **Blocked** = cannot be completed safely without the named external decision/work; **Deferred** = non-release architectural work; **Excluded** = testing-gap scope.

## Release gates

| Finding | Status | Resolution |
| --- | --- | --- |
| R-01 | Closed | One-time high-entropy remote setup token; tokenless setup is loopback-only. |
| R-02 | **Blocked** | Production MLS remains fail-closed. Shipping is prevented by `scripts/release-readiness.sh`; completion requires a reviewed protocol, OpenMLS integration, secure key lifecycle, interop vectors, and an independent crypto review. |
| R-03 | Closed | Reviewed Android/iOS projects and secure platform configuration are committed. |
| R-04 | Closed | Flutter 3.44.0, lockfile enforcement, source APIs, scripts, and CI are aligned. |
| R-05 | Closed | Channel kind is validated and channel/backing-conversation creation is atomic. |
| R-06 | Closed | Owner/register device/session/invite changes commit in one transaction. |
| R-07 | Closed | Last-owner deletion is forbidden; offline owner password recovery is audited. |
| R-08 | Closed | Private-conversation management requires actual membership. |
| R-09 | Closed | Envelope and durable sync event commit atomically before acknowledgement. |
| R-10 | Closed | Membership mutations emit durable account/conversation events. |
| R-11 | Closed | Restore validates staged database/blobs/checksums/migrations and swaps with rollback. |
| R-12 | Closed | Explicit flags preserve environment-derived database/blob paths. |
| R-13 | Closed | The pinned scratch image contains a writable UID-owned `/data`. |
| R-14 | Closed | Deletion wording matches behavior; credentials/metadata/memberships/private blobs are scrubbed with documented shared-history exceptions. |

## Security and correctness

| Findings | Status | Resolution |
| --- | --- | --- |
| SEC-01–SEC-02 | Closed | Owner-role invariants, membership checks, and per-account/conversation typing throttles are enforced. |
| SEC-03–SEC-06 | Closed | Device-secret proof, socket expiry/revocation, password rotation/recovery, and recent authentication are implemented. |
| SEC-07–SEC-10 | Closed | Invite lifecycle, identity validation, conversation shape, and same-conversation reply/thread checks are enforced. |
| SEC-11 | Closed | Test crypto lives under tests and reserved markers are rejected; production remains fail-closed under R-02. |
| SEC-12–SEC-13 | Closed | Versioned export categories and encrypted reaction retrieval/removal/tombstones are implemented. |
| SEC-14–SEC-15 | Closed | Authorized blob lifecycle, checksums, quotas, relational message references, expiry, and orphan cleanup are implemented. |
| SEC-16–SEC-18 | Closed | Community membership, bounded call state, and atomic idempotent message/event handling are implemented. |
| SEC-19 | Closed | Authenticated/sensitive responses explicitly disable caching. |

## Mobile, UI, and sync

| Findings | Status | Resolution |
| --- | --- | --- |
| MOB-01–MOB-08 | Closed | Paged/re-entrant catch-up, apply-before-cursor, account-scoped atomic state, pong handling, bounded reconnect, auth expiry, offline logout, and immediate startup shell are implemented. |
| MOB-09–MOB-17 | Closed | Search actions/race handling, bounded disposable HTTP, canonical HTTPS origins, registration parity, immutable routes, capability UI, and durable community reads are implemented. |
| MOB-18 | Closed | The supported UI language is explicitly English; dates/times use platform locale settings, decorative/duplicate semantics are excluded, and reduced-motion/large-text-safe layouts are retained. |
| MOB-19 | Closed | A bounded platform-encrypted ciphertext cache, atomic cursor snapshot, and idempotent encrypted outbox survive restart/offline use and are wiped on logout. Plaintext/key storage remains blocked by R-02. |
| MOB-20 | **Blocked** | Provider delivery needs an operator/provider choice and credentials plus platform registration/background entitlements. Generic payload and subscription boundaries remain enforced; no provider is silently selected. |
| MOB-21–MOB-23 | Closed | Atomic unique channel creation, sync epoch/bounds/full resync, and canonical account lookup are implemented. |

## Operations and architecture

| Findings | Status | Resolution |
| --- | --- | --- |
| OPS-01–OPS-06 | Closed | Full manifest backups, readiness/doctor checks, safe binds, privacy-safe route logs, resource caps, and strict PowerShell exit handling are implemented. |
| OPS-07 | **Excluded** | Testing-gap work excluded by user request. |
| OPS-08–OPS-10 | Closed | Immutable action/toolchain pins, permissions/timeouts/concurrency, pinned images, SPDX/checksum/provenance release workflow, and private security contact are implemented. |
| OPS-11–OPS-15 | Closed | Bounded retention jobs, route-aware upload deadlines, realtime budgets/drain, per-connection SQLite PRAGMAs, and indexed batched expiry are implemented. |
| OPS-16 | Closed | Core APIs use bounded stable cursors; mobile coalesces sync invalidations and persists deltas/cursor atomically. |
| OPS-17 | **Deferred** | Security/domain boundaries were narrowed, but the handler/store/client remain large modular-monolith files. Further splitting is maintainability work and must follow transaction-boundary characterization rather than a risky audit-time rewrite. |
| OPS-18–OPS-19 | Closed | Metrics use a separate loopback management listener and the configured/stored instance name is authoritative. |

## Verification

- `scripts/test.ps1`: passed (Go, Rust, Flutter; 23 Flutter tests).
- `scripts/lint.ps1`: passed with no formatting or analyzer changes.
- Pinned scratch server image: built successfully and its CLI executed as UID 65532.
