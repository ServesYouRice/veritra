# Merged audit findings

Reconciled: 2026-07-22
Current commit: 5c1bc05
Decision: NO-GO

This file is the canonical reconciliation of audits-fable and audits-codex.
It removes duplicates, separates verified defects from design choices and
speculative performance risks, and records corrections to false positives.

## Verification limits

The current source still contains the two baseline defects reported by the
Codex audit: the setup notice does not satisfy its committed test, and the
MobileScanner callback still uses the wrong locked API shape. The canonical
test and lint scripts could not be rerun on 2026-07-22 because Docker Desktop
was stopped and Go, Rust, and Flutter were not installed locally. The
audits-codex run from 2026-07-21 remains the latest executed baseline evidence.

Static verification checked the current tree, migrations, route table,
storage queries, Flutter state/persistence, deployment files, release
workflows, and relevant security and recovery documents.

## Canonical priorities

| Priority | Finding | Decision | Primary evidence |
| --- | --- | --- | --- |
| P0 | Production mobile MLS integration is incomplete | Confirmed; already tracked | LOG-02, SEC-01, UI-01, REMAINING-WORK.md |
| P0 | Server setup test is red | Confirmed | TEST-01, UI-12 |
| P0 | Flutter compile/analyze/test baseline is red | Confirmed by the 2026-07-21 run; source unchanged | TEST-02, UI-02 |
| P0 | Key-package claim queries nonexistent conversation_members | Confirmed current defect | LOG-01, TEST-03 |
| P0 | Mobile persistence is racy and too large for one secure-storage value | Confirmed current defect | LOG-03, PERF-01, TEST-04 |
| P0 | Device-link comparison code is server-authored, not credential-derived | Confirmed protocol defect | SEC-02 |
| P0 | Durable mutations and sync events are often separate commits | Confirmed convergence defect | LOG-04, TEST-06 |
| P0 | DMs can gain a third member | Confirmed privacy invariant defect | LOG-06 |
| P0 | Conversation membership lacks list, leave, and remove lifecycle | Confirmed product and MLS blocker | LOG-07, UI-05 |
| P0 | Catch-up cannot repair arbitrary old messages and mobile cannot load old history | Confirmed | LOG-08, UI-04 |
| P0 | Realtime per-IP limit counts the trusted proxy | Confirmed | LOG-05, TEST-05 |
| P0 | Production deploy examples omit production mode and safe secret wiring | Confirmed | SEC-03, SEC-07, DEP-01, DEP-02 |
| P0 | Large backup and attachment downloads use a 30-second deadline and no Range | Confirmed | LOG-09, PERF-08 |
| P0 | Release workflow has no signed, usable mobile artifacts/native crypto packaging | Confirmed and crypto-dependent | DEP-03 |
| P0 | Independent protocol/mobile security review is absent | Confirmed and intentionally deferred until implementation freezes | SEC-08 |
| P1 | DM rows lack peer identity and duplicate DMs are allowed | Confirmed | UI-03, LOG-12 |
| P1 | Block/unblock safety controls are unreachable in the app | Confirmed | UI-06 |
| P1 | One permanent outbox error blocks later messages | Confirmed | LOG-10 |
| P1 | Shared global busy/error state misattributes concurrent failures | Confirmed | LOG-11, UI-10 |
| P1 | Blob deletion failures have no durable reconciliation | Confirmed | LOG-14 |
| P1 | Instance backups are not scheduled, off-host, alerted, or rehearsed | Confirmed | DEP-04, TEST-10 |
| P1 | Single-process deployment is documented but not enforced | Confirmed | DEP-05 |
| P1 | Enrollment reservation routes miss the stricter limiter | Confirmed | LOG-13, SEC-06 |
| P1 | Message protocol marker is not allowlisted | Confirmed; implement with crypto activation | SEC-04 |
| P1 | Custom WebSocket parser lacks fuzz/conformance evidence | Confirmed risk | SEC-05, TEST-07 |
| P1 | Client/server API compatibility has no live contract test | Confirmed gap | TEST-08 |
| P1 | Users cannot independently verify peer credentials | Valid trust UX gap; derive comparisons client-side | MERGE-09 |
| P2 | Search, community navigation, forms, push status, and message actions are incomplete | Confirmed; split into bounded UI work | UI-07 through UI-11 |
| P2 | Metrics profile, graceful draining, version alignment, and runbooks are incomplete | Confirmed operations work | DEP-06 through DEP-09 |
| P2 | Accessibility and capacity lack real-device/load evidence | Confirmed verification work | UI-14, TEST-11, PERF-09 |

## Unique actionable findings retained from Fable

These were not fully represented in the Codex category files.

| Supplemental ID | Finding | Decision |
| --- | --- | --- |
| MERGE-01 | Password helper contains real mojibake | Fix the encoding, but keep the truthful 12–72 UTF-8 byte rule. |
| MERGE-02 | Blob write renames without file sync; serve path does not validate on-disk size | Valid durability hardening; combine with LOG-14 and restore testing. |
| MERGE-03 | Login has no per-account failure throttle | Defense-in-depth, not a launch blocker because password login also requires a valid linked-device secret. |
| MERGE-04 | Block/member audit metadata may reveal avoidable social-graph details to admins | Privacy-policy decision. The threat model already admits server-visible membership metadata, so this is minimization work, not a broken E2EE boundary. |
| MERGE-05 | Sessions are fixed 30-day bearer tokens with no inventory/rotation UX | Valid later hardening; device/session revocation already limits severity. |
| MERGE-06 | Small dead wrappers and unused client methods remain | Valid cleanup only after blocker work; do not churn active seams used by tests or planned crypto work. |
| MERGE-07 | Multi-account support, invite URI/QR, drafts, and ciphersuite constant centralization remain useful roadmap items | Valid deferred product/maintenance work. |
| MERGE-08 | Rate limits omit Retry-After and the client has no throttle-specific delay | Valid robustness work; combine the server header with bounded client backoff. |
| MERGE-09 | There is no peer safety-number/credential-verification UX | Valid trust gap; comparison values must be derived on clients, not authored by the server. |

## Performance findings are measurement-first

PERF-02 through PERF-07 are real code shapes, but they are not proven production
failures at the target scale. Do not denormalize or add infrastructure before
capturing a synthetic benchmark and EXPLAIN QUERY PLAN output.

- PERF-03: the existing migration already has an index on
  message_envelopes(conversation_id, created_at). The correlated unread query
  still needs measurement; “add that index” is not a remaining fix.
- PERF-04: hub registration is O(total connections); counter maps are a clear
  improvement after proxy identity is fixed.
- PERF-05: push delivery is sequential per message; use a bounded local queue
  only after behavior and shutdown semantics are specified.
- PERF-06: sync visibility repeats JSON extraction and bounds queries; an
  indexed routing column may help, but its metadata/privacy cost must be
  reviewed.
- PERF-07: quota aggregation may be adequate for small tables. Add counters
  only if benchmarks show writer contention.

## False positives and corrected recommendations

| Source finding | Disposition | Evidence/correction |
| --- | --- | --- |
| Fable L-8: one attachment can be shared by two messages and pruned incorrectly | False positive | Migration 0007 makes message_attachments.attachment_id UNIQUE, so one attachment cannot be linked to two messages. |
| Fable UI-12: BuildContext is used after an async gap before the insecure-URL dialog | False positive | _confirmInsecureUrl has no await before showDialog. |
| Fable S-7: storage keys are the only blob capability | Partly false | AttachmentForAccount/BackupForAccount authorize the caller before opening a blob. Missing integrity/size checks remain valid as MERGE-02. |
| Fable UI-3 recommendation to say “characters” | Recommendation rejected | The server enforces bcrypt’s UTF-8 byte limit. Correct only the mojibake and keep byte-accurate copy. |
| Fable L-13: admin password reset is a production blocker | Severity and fix rejected | Loss semantics are a product decision. Recovery must use a user-held secret or verified device and must not create admin impersonation/key escrow. Track under NICE-01/NICE-02. |
| Fable T-2: call every exported store method once as a schema check | Strategy corrected | Empty calls can exit before problematic SQL. Use targeted migration-backed tests for every high-risk query plus live API contract tests. |
| Fable P-1 suggestion to add conversation_id/created_at index | Already present | server/migrations/0001_init.sql already creates idx_messages_conversation_created. Benchmark the remaining query. |
| Fable S-4 framing that any admin-visible social graph breaks the privacy promise | Overstated | docs/threat-model.md explicitly states that the server sees membership/social metadata. Minimize unnecessary audit fields, but do not label this plaintext access. |

## Fable finding crosswalk

### UI

| Fable | Merged disposition |
| --- | --- |
| UI-1 | Confirmed → Codex UI-03 |
| UI-2 | Confirmed known blocker → Codex UI-01 / LOG-02 |
| UI-3 | Confirmed with corrected copy → MERGE-01 / Codex UI-09 |
| UI-4 | Confirmed, post-crypto → Codex UI-11 |
| UI-5 | Confirmed → Codex UI-04 / LOG-08 |
| UI-6 | Confirmed → Codex UI-10 / LOG-11 |
| UI-7 | Confirmed low priority → Codex UI-13 |
| UI-8 | Confirmed low priority → Codex UI-10 / LOG-11 |
| UI-9 | Confirmed → Codex UI-05 / LOG-06 / LOG-07 |
| UI-10 | Confirmed → Codex UI-10 |
| UI-11 | Confirmed privacy/product decision → Codex UI-11 / NICE-07 |
| UI-12 | Mixed: default URL and confirmation revalidation are valid polish; async-context claim is false |
| UI-13 | Mixed: block UI is P1; export/admin UI is later → Codex UI-06 / NICE-04 |
| UI-14 | Confirmed verification gap → Codex UI-14 / TEST-11 |

### Logic

| Fable | Merged disposition |
| --- | --- |
| L-1 | Confirmed → LOG-01 |
| L-2 | Confirmed → LOG-05 |
| L-3 | Confirmed → LOG-03 |
| L-4 | Confirmed → LOG-06 |
| L-5 | Confirmed → LOG-09 / PERF-08 |
| L-6 | Confirmed → LOG-11 |
| L-7 | Confirmed → LOG-10 |
| L-8 | False positive because attachment_id is unique |
| L-9 | Confirmed → LOG-14 |
| L-10 | Confirmed low durability issue → MERGE-02 |
| L-11 | Confirmed → LOG-08 |
| L-12 | Confirmed → LOG-07 |
| L-13 | Gap valid; blocker severity/admin-reset fix rejected → NICE-01/NICE-02 |
| L-14 | Confirmed and broader than stated → LOG-04 |
| L-15 | Confirmed → LOG-13 / SEC-06 |
| L-16 | Verified non-issue; no action |
| Dead-code table | Partly valid cleanup → MERGE-06 |

### Security

| Fable | Merged disposition |
| --- | --- |
| S-1 | Confirmed → SEC-03 |
| S-2 | Confirmed risk → SEC-05 |
| S-3 | Enrollment half confirmed → SEC-06; per-account throttle retained as MERGE-03 |
| S-4 | Reframed as optional metadata minimization → MERGE-04 |
| S-5 | Protocol allowlist confirmed → SEC-04; heuristic guards remain defense-in-depth |
| S-6 | Valid later hardening → MERGE-05 |
| S-7 | Authorization wording false; integrity portion retained → MERGE-02 |
| S-8 | Verified non-issues; no action |

### Performance

| Fable | Merged disposition |
| --- | --- |
| P-1 | Confirmed measurement target → PERF-03; proposed index already exists |
| P-2 | Confirmed → PERF-02 |
| P-3 | Confirmed → PERF-04 |
| P-4 | Confirmed → PERF-05 |
| P-5 | Confirmed → PERF-06 |
| P-6 | Confirmed blocker with LOG-03 → PERF-01 |
| P-7 | Confirmed measurement target → PERF-07 |
| P-8 | Confirmed blocker with LOG-09 → PERF-08 |
| P-9 | Verified non-issues; no action |

### Testing

| Fable | Merged disposition |
| --- | --- |
| T-1 | Confirmed → TEST-03 |
| T-2 | Gap valid, proposed blanket smoke strategy corrected → TEST-03 / TEST-08 |
| T-3 | Confirmed → TEST-05 |
| T-4 | Confirmed → TEST-07 |
| T-5 | Mixed: shared-attachment case is invalid; cleanup failure/reconciliation tests remain valid |
| T-6 | Confirmed → TEST-04 |
| T-7 | Confirmed → TEST-08 |
| T-8 | Confirmed/known → TEST-09 |
| T-9 | Confirmed → TEST-10 |
| T-10 | Valid regression backlog; use risk-based gates rather than a raw coverage percentage |

### Deployment

| Fable | Merged disposition |
| --- | --- |
| D-1 | Confirmed → DEP-01 |
| D-2 | Confirmed → DEP-02; use secret injection, not a committed CHANGE-ME value |
| D-3 | Confirmed → DEP-04 |
| D-4 | Confirmed → DEP-05 |
| D-5 | Confirmed operations gap → DEP-06 |
| D-6 | Confirmed → DEP-07 |
| D-7 | Confirmed → DEP-08 |
| D-8 | Confirmed → DEP-09 |

### Fable unnumbered nice-to-haves

| Fable group | Merged disposition |
| --- | --- |
| Display identity, peer verification, local search, recovery, membership, multi-account, iOS push, Retry-After | Preserved in M04/M09, R01/R02/R05/R16, M01–M03/M07, S05/Y06/U07 |
| Invite/QR, mute, drafts, delivery state, connect/empty states, operator UI, storage visibility | Preserved in R03/R04/R06 and U06/U07; minor empty-state polish stays after functional flows |
| Schema tests, API contract/generation, scoped commands, errors, coverage, dev environment, dead code | Preserved in B04, V01/V04, R14/R15 |
| WebSocket library/fuzzing, encrypted local DB, structured sync routing, deferred adapters/queues | Preserved in V03, C01–C04, P05/P06, and measurement-first infrastructure rules |
| Encrypted previews, voice notes, moderation reports, client import, post-quantum readiness | Preserved as triggered roadmap work in R10–R13 |
| Federation | Still out of scope; reconsider only after an approved product requirement |

## Deferred product and architecture items

The useful nice-to-haves from both audits are preserved in
implementation/09-deferred-roadmap.md. Postgres, S3, NATS, federation, and a
desktop client are not current fixes. They require explicit measured or product
triggers. Client-side search, encrypted backup UX, profiles, multi-account
support, invite QR/URI, drafts, passkeys, calls, native notifications, encrypted
content extensions, moderation, and client-side imports remain valid future
work.
