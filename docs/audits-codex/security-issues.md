# Security and Privacy Issues

This review treats metadata, capabilities, device identity, and cryptographic state as sensitive even when message bodies remain encrypted.

## Summary

| ID | Severity | Finding | Blocker |
| --- | --- | --- | --- |
| SEC-01 | Critical | Recovery capability tokens are logged verbatim | Yes |
| SEC-02 | High | Account export lacks recent authentication and exports active push credentials | Yes |
| SEC-03 | High | Production cryptography still has unresolved review and advisory gates | Yes |
| SEC-04 | High | Reauthentication is outside strict credential rate limiting/backoff | Yes |
| SEC-05 | High | Android secure-storage recovery can silently orphan the encrypted database | Yes |
| SEC-06 | Medium | Dynamic object identifiers are retained in request logs | No |
| SEC-07 | Medium | Username-only login backoff enables distributed account lockout | No |
| SEC-08 | Medium | Recovery capabilities are reusable and have no explicit expiry | Yes with SEC-01 |
| SEC-09 | Medium | Broad trusted-proxy CIDRs can make client identity spoofable | No |
| SEC-10 | Medium | Binary API error/download bodies are not consistently bounded on mobile | No |

## Findings

### SEC-01 - Recovery capability tokens are logged verbatim

- **Severity:** Critical
- **Location:** `server/internal/httpapi/api.go:58`; `server/internal/httpapi/content_handlers.go:190-203`; `server/internal/app/app.go:333-350,472-496`
- **Description:** Backup recovery uses `GET /api/v1/recovery/{token}`. The request logger classifies `r.URL.Path`, and `routeClass` has no recovery rule, so the full 32-byte bearer capability is written into application logs. This was reproduced against the isolated production container with a fake valid-length token; the log contained `route=/api/v1/recovery/AAAA...` for the 404 response. Upstream proxies and request tooling can also retain URL paths.
- **Why it matters for production:** Anyone who can read access logs can download the latest encrypted backup. The encryption key may be distributed with the recovery material, so leaking this capability can defeat the intended separation. It directly violates the repository rule that tokens must never be logged.
- **Recommended fix:** Move the capability out of the URL, preferably to an authorization-style header on a non-cacheable request. Independently change logging to use the matched `r.Pattern` after routing and add a final fail-closed sanitizer for unknown paths. Rotate all capabilities that may have been requested, restrict/purge affected logs and proxy logs, and add a test asserting that a sentinel capability never appears in any log field.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Reverse-proxy logging, support bundles, SEC-08, incident response, and recovery UX.

### SEC-02 - Account export lacks recent authentication and exports active push credentials

- **Severity:** High
- **Location:** `server/internal/httpapi/api.go:100`; `server/internal/httpapi/call_sync_handlers.go:187-209`; `server/internal/storage/account_store.go:42-56`
- **Description:** `GET /api/v1/account/export` uses ordinary `withAuth`, while password changes, account deletion, invite creation, and device revocation require `withRecentAuth`. The export includes push endpoint, public key, and `auth_secret`, as well as devices, key packages, social metadata, ciphertext records, and audit history.
- **Why it matters for production:** A stolen long-lived bearer token can extract a comprehensive account dossier and active push authentication material without knowing the password/device secret. The endpoint also has a five-minute deadline, increasing the value of a single stolen session.
- **Recommended fix:** Require recent authentication and record a dedicated export audit event. Do not export active push `auth_secret` values; represent the subscription metadata without reusable credentials. Consider an encrypted asynchronous export with one-time download and expiry for large accounts.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Session lifetime, export UI, data portability requirements, and rate limiting.

### SEC-03 - Production cryptography still has unresolved review and advisory gates

- **Severity:** High
- **Location:** `crypto/rust/Cargo.lock`; `scripts/audit-rust.sh`; `docs/board.md` I24/I25/I27; `mobile/lib/main.dart`; `crypto/rust/src/lib.rs`
- **Description:** The current build correctly fails closed with `UnavailableCryptoService` and `PM_CRYPTO_UNAVAILABLE`. The locked OpenMLS/HPKE graph is subject to six RustSec advisories covered by narrow temporary exceptions; the project argues the affected optional/PQ branches are unreachable under the pinned classical suite. Independent security review, signed mobile candidates, real-device validation, and final evidence binding remain incomplete. The exception requires re-review by 2026-08-29.
- **Why it matters for production:** This audit cannot elevate a dependency reachability argument into cryptographic assurance. Enabling messaging before the coordinated dependency update and independent review would expose identity, epoch, state-rollback, FFI, and platform-build boundaries without the project's own required evidence.
- **Recommended fix:** Keep both fail-closed gates. Re-run the guarded audit immediately before release; upgrade to a coordinated stable OpenMLS/HPKE release when available; remove exceptions only after lockfile/SBOM/vector/native-build review. Complete I24/I25 with an immutable candidate and independent reviewer sign-off. Current RustSec records: [0209](https://rustsec.org/advisories/RUSTSEC-2026-0209.html), [0211](https://rustsec.org/advisories/RUSTSEC-2026-0211.html), [0124](https://rustsec.org/advisories/RUSTSEC-2026-0124.html), [0212](https://rustsec.org/advisories/RUSTSEC-2026-0212.html), [0207](https://rustsec.org/advisories/RUSTSEC-2026-0207.html), [0208](https://rustsec.org/advisories/RUSTSEC-2026-0208.html).
- **Blocker before production:** Yes.
- **Related risks or dependencies:** Release governance, MLS vectors, mobile native packaging, and DEP-01.

### SEC-04 - Reauthentication is outside strict credential rate limiting/backoff

- **Severity:** High
- **Location:** `server/internal/httpapi/api.go:62`; `server/internal/app/app.go:552-603`; `server/internal/httpapi/auth_handlers.go:725-750`
- **Description:** `/api/v1/auth/reauth` performs bcrypt and checks the device secret, but `isAuthEndpoint` excludes it. It receives only the broad 240-requests/minute per-IP limiter and does not use `LoginBackoff`. An attacker with a session token can drive substantially more expensive credential checks than the 10/minute login boundary.
- **Why it matters for production:** A stolen bearer token gains a faster password/device-secret guessing oracle and an authenticated CPU-exhaustion path. Shared-IP general limiting is too coarse to be the only defense.
- **Recommended fix:** Put reauthentication under a stricter per-session/account/device and per-source limiter, use progressive backoff, and revoke or challenge sessions after sustained failures. Preserve uniform error and timing behavior. Add tests covering limiter classification and backoff reset.
- **Blocker before production:** Yes because recent authentication protects the highest-risk actions.
- **Related risks or dependencies:** SEC-02, login backoff, session revocation, and abuse monitoring.

### SEC-05 - Android secure-storage recovery can silently orphan the encrypted database

- **Severity:** High
- **Location:** `mobile/lib/storage/local_store.dart:505-530,939-966`; `mobile/lib/core/app_state.dart:209-261`; `mobile/lib/main.dart:25-30`
- **Description:** The database encryption key is the sole value in `flutter_secure_storage`, configured with `AndroidOptions(resetOnError: true)`. Package behavior treats many key-storage errors as unrecoverable and may reset secure storage. The existing startup path then swallows restoration failures and returns to Connect; it does not distinguish a logged-out user from a missing/orphaned database key or present a recovery path.
- **Why it matters for production:** A Keystore/migration failure can make all local MLS state and ciphertext inaccessible. Silent fallback encourages users to sign in over an unreadable database and obscures whether recovery or device re-enrollment is required. Loss of MLS state is more serious than loss of an ordinary refresh token.
- **Recommended fix:** Define and test an explicit key-loss policy. Detect an existing encrypted DB with a missing/unreadable key before creating a replacement; transition to `recoveryRequired`, preserve the orphaned file, and offer verified restore/relink/reset choices. Review whether `resetOnError` is acceptable for this threat model and pin/test plugin migrations on every supported Android version.
- **Blocker before production:** Yes.
- **Related risks or dependencies:** LOG-03, backup/recovery, Android upgrades, and hardware-backed Keystore behavior.

### SEC-06 - Dynamic object identifiers are retained in request logs

- **Severity:** Medium
- **Location:** `server/internal/app/app.go:333-350,472-496`; routes in `server/internal/httpapi/api.go`
- **Description:** `routeClass` normalizes selected prefixes but misses dynamic routes including recovery, MLS messages, account blocks, admin accounts, and invites. Those paths log message/account/invite IDs. Metrics already use `r.Pattern`, but logs use the raw path classifier.
- **Why it matters for production:** Logs become a social/administrative metadata store and can correlate account actions over time. New dynamic routes are unsafe by default because omission means raw logging.
- **Recommended fix:** Log the matched method/path pattern from `r.Pattern`, falling back to a constant such as `unmatched` rather than the URL. Add table-driven coverage for every route and sentinel values. Keep query strings excluded.
- **Blocker before production:** No once SEC-01 is fixed, but it should be addressed in the same patch.
- **Related risks or dependencies:** Privacy policy, operator log retention, and metrics cardinality.

### SEC-07 - Username-only login backoff enables distributed account lockout

- **Severity:** Medium
- **Location:** `server/internal/httpapi/login_backoff.go`; `server/internal/httpapi/auth_handlers.go:205-235`
- **Description:** Progressive backoff is keyed only by normalized username. Any failures against that name affect the legitimate user regardless of source. A distributed attacker can repeatedly extend delays while staying below each per-IP limit.
- **Why it matters for production:** The defense against guessing becomes an account availability attack. It is especially disruptive for an owner account during an incident.
- **Recommended fix:** Combine source, account, and device/session dimensions: strong per-source throttling, bounded account-level delay, challenge/alerting after suspicious distributed failures, and privacy-safe aggregate metrics. Ensure an attacker cannot indefinitely extend a lock with unauthenticated attempts.
- **Blocker before production:** No; current delay is bounded, but abuse controls should be productionized.
- **Related risks or dependencies:** SEC-04, owner recovery, and proxy identity correctness.

### SEC-08 - Recovery capabilities are reusable and have no explicit expiry

- **Severity:** Medium
- **Location:** `server/internal/storage/content_store.go:560-608`; recovery API
- **Description:** Uploading a newer backup invalidates older capabilities for the same device, but `BackupForRecoveryToken` only reads the current token hash. A successful recovery does not consume the token, and the record carries no separate capability expiry.
- **Why it matters for production:** Any copied capability remains a reusable download credential until another backup is uploaded or the backup is deleted. SEC-01 makes this lifetime especially dangerous.
- **Recommended fix:** Decide and document one-time versus multi-use recovery. Prefer a one-time token or short-lived exchange that atomically consumes/rotates the capability, with explicit user-controlled regeneration and privacy-safe audit events. Never record the capability itself.
- **Blocker before production:** Yes in combination with SEC-01; otherwise policy-dependent.
- **Related risks or dependencies:** Offline recovery UX, resumable downloads, and backup rotation.

### SEC-09 - Broad trusted-proxy CIDRs can make client identity spoofable

- **Severity:** Medium
- **Location:** `server/internal/config/config.go:113-130`; client identity resolver; `PRIVATE_MESSENGER_TRUSTED_PROXIES`
- **Description:** Production validation requires at least one trusted proxy CIDR for a non-loopback listener but does not reject overly broad networks such as `0.0.0.0/0`. If an operator supplies one, direct clients are treated as trusted and can influence forwarded client-IP headers used by rate limiting and WebSocket per-IP limits.
- **Why it matters for production:** A configuration typo can silently disable source-based abuse controls and pollute identity-derived operational behavior.
- **Recommended fix:** Reject unspecified/all-address CIDRs and public ranges unless an explicit dangerous override is set. On startup, log only safe aggregate posture plus a warning/failure for broad trust. Document exact Caddy/container network values and test spoofed forwarding chains.
- **Blocker before production:** No for the supplied Compose configuration, which uses a narrow private subnet.
- **Related risks or dependencies:** SEC-04, SEC-07, reverse-proxy topology, and multi-proxy deployments.

### SEC-10 - Binary API error/download bodies are not consistently bounded on mobile

- **Severity:** Medium
- **Location:** `mobile/lib/core/api_client.dart:319-407`
- **Description:** Ordinary JSON responses are capped at 2 MiB. Attachment upload responses and backup upload/recovery error bodies use unbounded `fold` or `utf8.decodeStream`, and successful download streams are returned without checking expected content length at the HTTP boundary.
- **Why it matters for production:** A compromised/misconfigured instance can stream an arbitrarily large body and exhaust device memory or storage. Users explicitly connect the app to self-hosted origins, so hostile-server behavior belongs in the client threat model.
- **Recommended fix:** Apply a small common error-body cap, validate `Content-Length` where present, and wrap successful streams in an exact maximum-byte limiter derived from endpoint policy/metadata. Abort and close the response on overflow.
- **Blocker before production:** No while attachment/recovery UI is gated, but required before those flows ship.
- **Related risks or dependencies:** Attachment/recovery implementation, disk-space UX, and redirect policy.
