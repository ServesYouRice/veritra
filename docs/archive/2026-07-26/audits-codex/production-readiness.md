# Production Readiness Decision

**Audit date:** 2026-07-21  
**Decision:** **NO-GO**

Veritra has a thoughtful privacy-first server foundation, but the audited commit cannot support production users. Core mobile messaging is fail-closed, MLS key-package claiming is broken, server/mobile baselines are red, and several data-convergence, membership, bootstrap, recovery, and deployment controls are incomplete.

## Readiness scorecard

| Area | Status | Reason |
| --- | --- | --- |
| Core messaging | Red | Mobile cannot encrypt/decrypt; key-package claim always fails. |
| E2EE/device trust | Red | Native integration, local SAS linking, recovery, revocation, and independent review are incomplete. |
| Mobile build/UI | Red | Flutter compile/analyze/test failure; message UI remains placeholder. |
| Data integrity/sync | Red | Local persistence races; many mutations are not atomic with durable events. |
| Authorization/safety | Red | DMs can gain extra members; leave/remove and block UI are missing. |
| Deployment | Red | Production mode/setup secret/mobile releases/backups/single-process enforcement are incomplete. |
| Testing | Red | Both canonical aggregate commands fail; critical paths have no integration coverage. |
| Performance | Amber | Single-node design is suitable, but hot paths and capacity lack measurement. |
| Observability | Amber | Privacy-safe metrics exist, but default deployment cannot practically scrape/alert on them. |
| Privacy foundations | Green/Amber | Ciphertext-only intent, safe logging, generic push, scoped admin, and fail-closed crypto gate are strong; full E2EE is not yet delivered. |

## Launch blockers

| Order | Blocker | Primary evidence |
| ---: | --- | --- |
| 1 | Restore green server and Flutter compile/test/lint baselines. | `TEST-01`, `TEST-02` |
| 2 | Fix conversation key-package claims against the real schema. | `LOG-01`, `TEST-03` |
| 3 | Complete native MLS mobile integration with transactional state/cursor persistence. | `LOG-02`, `LOG-03`, `SEC-01`, `TEST-09` |
| 4 | Replace server-authored link codes with locally derived credential SAS verification. | `SEC-02` |
| 5 | Make edits/deletes/reactions/receipts/retention/calls atomic with durable sync events. | `LOG-04`, `TEST-06` |
| 6 | Enforce two-account DMs and complete list/leave/remove member lifecycle with MLS coordination. | `LOG-06`, `LOG-07`, `UI-05` |
| 7 | Make durable catch-up repair any message and expose older history. | `LOG-08`, `UI-04` |
| 8 | Fix trusted-proxy realtime limits on the supported Caddy path. | `LOG-05`, `TEST-05` |
| 9 | Make DMs unambiguous and expose block/unblock safety controls. | `UI-03`, `UI-06` |
| 10 | Require production mode and a safe one-time setup secret. | `SEC-03`, `SEC-07`, `DEP-01`, `DEP-02` |
| 11 | Provide reliable ranged backup/attachment downloads and tested off-host restore operations. | `LOG-09`, `PERF-08`, `DEP-04`, `TEST-10` |
| 12 | Enforce single-process deployment and ship signed, provenance-tracked mobile artifacts. | `DEP-03`, `DEP-05` |
| 13 | Complete internal adversarial testing and independent protocol/mobile security review. | `SEC-08` |

No Critical or High issue should be accepted as production risk for a privacy-first messenger.

## Recommended implementation waves

### Wave 0 — Make the repository trustworthy again

- Fix the setup-page test contract and scanner callback.
- Require clean `test`, `lint`, release builds, and release gate behavior in protected CI.
- Add the missing key-package endpoint integration test first, then fix the query.

### Wave 1 — Complete the security/data core

- Replace the secure-storage mega-record with an encrypted transactional local database.
- Wire MLS ABI v2 end to end, including group/epoch operations and state restoration.
- Implement credential-derived device-link SAS.
- Make every durable mutation/event atomic and add single-message/event repair semantics.
- Enforce production protocol allowlists and DM/member invariants.

### Wave 2 — Complete user-safety flows

- Render identifiable canonical DMs.
- Add pagination, offline/outbox state, block/unblock, member list/leave/remove, and correct search/navigation.
- Add encrypted attachments and message actions only after authenticated payload handling is proven.
- Verify accessibility, narrow/large-text, tablet, background, and real-device behavior.

### Wave 3 — Build an operable release

- Add safe production Compose/systemd secret profiles and an instance lock.
- Build/sign/package native crypto and Android/iOS apps with compatibility metadata.
- Automate off-host backups, restore drills, metrics scraping, alerts, upgrades, and rollback runbooks.
- Run load/soak testing against a declared small-instance capacity envelope.

### Wave 4 — Independent assurance and controlled rollout

- Freeze the protocol/recovery implementation and commission independent review.
- Remediate findings and bind the report to the release commit.
- Run an invite-only pilot with synthetic/consenting test users, aggressive backup verification, and a rollback plan before general self-hosting.

## Verification required for a future go decision

- [ ] Canonical server, Rust, and Flutter tests/lint/builds pass from clean pinned environments.
- [ ] Release-readiness gate passes for the right reason—production crypto is present and reviewed.
- [ ] Android and iOS real devices complete setup, invite registration, DM/group creation, multi-device link, offline send/catch-up, edit/delete, block, member removal, process death, and restore.
- [ ] No server table/log/export/push/admin response contains plaintext message or attachment content.
- [ ] Failure injection proves atomic MLS state/cursor/outbox and server mutation/event commits.
- [ ] Proxy integration proves safe setup authorization, spoof-resistant throttling, and correct realtime connection limits.
- [ ] Backup of a representative encrypted instance restores on a clean host and passes `doctor`/hash checks within stated RTO.
- [ ] Signed mobile artifacts and server release have SBOM/provenance and a documented compatibility matrix.
- [ ] Independent review findings are closed or explicitly documented as non-blocking residual risk.

## Notable strengths to preserve

- The server is a clear Go modular monolith with storage, push, uploads, realtime, and crypto boundaries behind interfaces.
- New-message envelope and sync-event persistence is transactional and idempotent.
- The incomplete crypto path fails closed and an explicit release gate prevents accidental production claims.
- Schema/API/logging/admin/push design consistently avoids plaintext message content and request-body logging.
- Migration checksums, foreign keys, WAL configuration, security headers, trusted-proxy validation, push SSRF defenses, scratch non-root image, SBOM, and provenance are solid foundations.
- Backup/restore design includes staging, manifests, hashes, and rollback intent; it now needs operational proof.

## Audit limitations

- This was static/runtime repository review, not penetration testing or formal cryptographic verification.
- Flutter screenshots/emulator review were blocked by the compile error; the embedded setup page could not be browser-rendered in the available environment.
- No production dataset, external push provider, signed mobile environment, or real devices were available.
- Performance risks are code-path assessments until reproducible load measurements exist.

