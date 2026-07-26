# Security and Privacy Issues

**Audit date:** 2026-07-21  
**Security verdict:** No-go; no independent cryptographic/security review is evidenced.

## Findings

### SEC-01 — The production E2EE boundary is incomplete

| Field | Detail |
| --- | --- |
| Severity | Critical |
| Location | `mobile/lib/main.dart`; `mobile/lib/crypto`; `crypto/rust`; `docs/crypto-protocol.md` |
| Blocker before production | **Yes** |

**Description:** OpenMLS primitives exist, but the actual mobile service, platform packaging, protected key lifecycle, group orchestration, authenticated payload validation, backup/recovery, and revocation path are incomplete and fail closed.

**Why it matters:** E2EE is the product's primary security claim. Shipping an unreviewed partial path risks key compromise, epoch rollback, unauthenticated roster changes, or plaintext fallback.

**Recommended fix:** Complete the documented contract, publish test evidence for every lifecycle, and obtain an independent review of protocol integration plus Android/iOS key handling before removing the release gate.

**Risks/dependencies:** Depends on `LOG-01`, transactional local storage, MLS interoperability/offline tests, recovery design, device removal, and signed platform packaging.

### SEC-02 — Device-link verification is controlled by the server

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | device-link store/handlers; `mobile/lib/features/settings/device_link_screen.dart`; `docs/crypto-protocol.md` identity contract |
| Blocker before production | **Yes** |

**Description:** The server generates and returns the six-digit verification code used by both devices. It is not a short authentication string derived locally from both device credentials/transcript.

**Why it matters:** A malicious or compromised server—the documented adversary—can mediate what each device sees and cannot be detected by comparing a server-authored value. The approval UX overstates cryptographic device verification.

**Recommended fix:** Exchange authenticated public credential material and derive the same SAS locally on both devices from a domain-separated transcript. Require human comparison before the existing device authorizes the new credential; bind approval to that transcript.

**Risks/dependencies:** Requires production crypto, stable credential encoding, replay-resistant link transcripts, QR/manual fallback, and usability testing. Server approval remains useful but is not sufficient.

### SEC-03 — Tokenless setup trusts loopback even behind a local reverse proxy

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/httpapi/auth_handlers.go:180-191`; deployment modes |
| Blocker before production | **Yes** for any remotely reachable setup |

**Description:** If no setup token is configured, owner setup trusts `r.RemoteAddr.IsLoopback()`. A reverse proxy connected to the app over `127.0.0.1` makes remote requests appear loopback. The bundled bridge-network Caddy path is not loopback, but the documented/general reverse-proxy deployment can be.

**Why it matters:** During first boot, a remote attacker could claim the owner account and fully control the instance.

**Recommended fix:** Require a high-entropy setup token whenever setup is incomplete, or require an explicitly activated one-time local setup mode that cannot be reached through the public listener. Fail production startup if the owner is absent and neither safe mechanism is configured.

**Risks/dependencies:** Do not use forwarded headers to authorize setup. Rotate/remove the token after success and redact it from all logs/process arguments.

### SEC-04 — Message APIs accept arbitrary/non-production protocol markers

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `server/internal/httpapi/conversation_handlers.go`; message store; tests using `mls-openmls-todo`; `docs/crypto-protocol.md` |
| Blocker before production | **Yes** when production crypto is enabled |

**Description:** Message create/edit/delete require only a non-empty `crypto_protocol`; unlike call signaling, they do not allowlist `mls10-openmls-v1`. Tests normalize an obsolete `mls-openmls-todo` marker. The forbidden-field heuristic cannot prove bytes are ciphertext.

**Why it matters:** A broken or malicious client can populate production storage with non-production/ambiguous payloads that other clients cannot authenticate, undermining fail-closed protocol negotiation.

**Recommended fix:** In production mode, accept only reviewed versioned protocols and bounded metadata schemas. Reject test/placeholder markers explicitly and add negative API/storage tests. Clients must still cryptographically authenticate decrypted payloads.

**Risks/dependencies:** Plan explicit protocol upgrades so an allowlist does not strand old ciphertext. The server should validate framing/version, not attempt plaintext inspection or decryption.

### SEC-05 — Realtime uses a custom WebSocket implementation without adversarial assurance

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/realtime/websocket.go`; `websocket_test.go` |
| Blocker before production | No, but security review/fuzzing is required |

**Description:** Security-sensitive frame parsing, handshake, masking, control frames, deadlines, and fragmentation are implemented in-house. Tests cover basic handshake/ping/unmasked behavior but there is no fuzz target or protocol-conformance suite.

**Why it matters:** Parser edge cases can cause resource exhaustion, connection desynchronization, or panics on the authenticated realtime endpoint.

**Recommended fix:** Prefer a mature, license-compatible WebSocket library after dependency review. If retaining custom code, validate version/key headers and fragmentation state, add fuzzing for frame streams/lengths/control sequences, and run an RFC conformance suite under race detection.

**Risks/dependencies:** A new dependency requires `THIRD_PARTY_NOTICES.md` review. Preserve authorization-before-upgrade, origin policy, session expiry, and privacy-safe logging.

### SEC-06 — Unauthenticated enrollment routes use overly broad abuse limits

| Field | Detail |
| --- | --- |
| Severity | Medium |
| Location | `server/internal/app/app.go:isAuthEndpoint`; enrollment reservation handlers/store |
| Blocker before production | No |

**Description:** Setup, invite-registration, and device-link reservation endpoints are excluded from the stricter auth rate class even though they create database state and disclose typed validity outcomes.

**Why it matters:** This expands invite/link probing and reservation/DB-exhaustion opportunities.

**Recommended fix:** Apply strict endpoint-specific rate limits, outstanding-reservation caps, uniform external errors where practical, and `Retry-After`; retain dummy bcrypt work for username misses.

**Risks/dependencies:** Trusted-proxy correctness is prerequisite. Avoid persistent raw-IP telemetry.

### SEC-07 — Production deployment does not require the setup secret by default

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `deploy/docker-compose.yml`; `server/config.example.env`; setup notice |
| Blocker before production | **Yes** for the recommended public deployment |

**Description:** Compose configures neither `PRIVATE_MESSENGER_ENV=production` nor `PRIVATE_MESSENGER_SETUP_TOKEN`. Documentation tells operators to add them, but the executable configuration remains permissive/development by default.

**Why it matters:** Copy/paste deployment can miss fail-fast production validation and leave first-owner bootstrap inaccessible or unsafe depending on the proxy topology.

**Recommended fix:** Provide a production Compose override/example that requires an external secret and production mode, refuses placeholders, and documents token removal after setup. Make unsafe defaults visibly fail for public profiles.

**Risks/dependencies:** Do not commit a sample real token. Integrate Docker secrets/systemd credentials where supported.

### SEC-08 — Security claims lack independent release evidence

| Field | Detail |
| --- | --- |
| Severity | High |
| Location | `SECURITY.md`; release workflow; crypto/recovery/threat-model docs |
| Blocker before production | **Yes** |

**Description:** The repository explicitly states it has not been independently audited. There is no published threat-model sign-off, mobile key-handling assessment, protocol integration report, or remediation record.

**Why it matters:** Internal tests cannot establish that a new MLS integration or recovery path preserves the advertised privacy boundary.

**Recommended fix:** Freeze the protocol/recovery design, commission independent review, track findings to closure, and attach the reviewed commit/version and residual risks to release notes.

**Risks/dependencies:** Review too early will be invalidated by the still-missing mobile integration; schedule it after implementation and internal adversarial testing.

## Verified positive controls

- Message APIs recursively reject obvious plaintext field names and the schema stores message bodies as ciphertext blobs.
- Request logs use bounded route patterns and omit bodies, query strings, tokens, ciphertext, and account identifiers.
- Push payload content is fixed and generic; endpoint validation includes HTTPS, public-network dialing, DNS pinning, bounded redirects/responses, and no ambient proxy.
- Password hashing rejects bcrypt truncation beyond 72 bytes and performs dummy verification for missing accounts.
- Sessions are stored as token hashes; device/session revocation disconnects active sockets.
- Security headers, migration checksums, SQLite foreign keys/WAL settings, and privacy-scoped admin responses are present.

These controls are valuable, but they do not offset the launch blockers above.

