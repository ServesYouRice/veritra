# Security Issues

Baseline: strong. Bcrypt with dummy-hash timing equalization, hashed session tokens and device secrets, Ed25519 enrollment proofs bound to challenge+key-package hash, constant-time compares on setup token / device secret / verification code, invite-only registration, ciphertext-only persistence with plaintext-key request rejection, strict security headers, SSRF-hardened push dialer (public-IP-only, no redirects), pinned CI actions and image digests, scratch container as non-root. Findings below are the residual risks.

---

## S-1. Tokenless owner setup trusts loopback `RemoteAddr` — defeated by a same-host reverse proxy

- **Severity:** High
- **Location:** `server/internal/httpapi/auth_handlers.go:180-192` (`setupAuthorized`); deployment shape: `deploy/systemd/private-messenger.service` (`PRIVATE_MESSENGER_ADDR=127.0.0.1:8080`, TLS expected at a host-local reverse proxy)
- **Problem:** When no `PRIVATE_MESSENGER_SETUP_TOKEN` is set, setup authorization falls back to "is `RemoteAddr` loopback?". In the documented systemd topology the app listens on `127.0.0.1:8080` behind a reverse proxy *on the same host* — so **every external request arrives from 127.0.0.1** and passes the loopback check. Between first boot and owner creation, any Internet client that can reach the proxy can create the owner account without a token. (The Compose topology is safe by accident: Caddy connects from a bridge-network IP.) The README's claim "tokenless setup is loopback-only" is not true in this deployment.
- **Why it matters:** First-boot race for instance takeover — the classic self-hosted-app setup vulnerability. The window is small for careful operators but unbounded for anyone who deploys, then configures DNS/clients "tomorrow".
- **Recommended fix (pick one or combine):**
  1. Refuse to serve setup endpoints tokenless whenever `TrustedProxies` is configured or `Environment == "production"` (fail closed: production ⇒ token required).
  2. Resolve the client IP through the same trusted-proxy XFF logic as the rate limiter before applying the loopback test.
  3. Have `init` generate and print a random setup token when none is configured.
- **Blocker before production:** Yes.
- **Related:** deployment-risks D-2 (compose also omits `PRIVATE_MESSENGER_ENV=production`, which weakens `ValidateServe`'s guardrails).

## S-2. Custom WebSocket server implementation is high-risk parsing code with no adversarial tests

- **Severity:** Medium–High
- **Location:** `server/internal/realtime/websocket.go` (hand-rolled RFC 6455 framing: `drainClientFrames`, `writeTextFrame`, handshake)
- **Problem:** The implementation is careful (mask enforcement, control-frame size caps, 1 MiB frame cap, read deadlines, RSV-bit rejection) but it is still bespoke binary-protocol parsing exposed pre-… actually post-auth, to every authenticated user. Observed nits: fragmented data frames (FIN=0, opcode 1/2) are accepted and *discarded without tracking continuation state*, and `length` from a 64-bit field is cast through `int64` then compared — fine on 64-bit, but the code allocates `make([]byte, length)` up to 1 MiB per frame per connection with no aggregate cap. No fuzz tests exist for the parser.
- **Why it matters:** Framing bugs are memory-safety-adjacent in Go only in the DoS sense, but protocol-state confusion (e.g., a close frame smuggled in a fragment) is exactly what fuzzers find. This code path holds hijacked connections outside all server timeouts.
- **Recommended fix:** Add a `go-fuzz`/`testing.F` fuzz target for `drainClientFrames` against a `net.Pipe`; alternatively adopt a maintained minimal library (`nhooyr.io/websocket` a.k.a. `github.com/coder/websocket`, license-compatible) and delete the bespoke parser. Also reject fragmented frames explicitly (server never needs them — clients only send pings/pongs/close).
- **Blocker before production:** Fuzzing or library swap: strongly recommended; the independent security review already planned should explicitly include this file.

## S-3. Authentication endpoints without per-account throttling; enrollment endpoints outside the auth rate class

- **Severity:** Medium
- **Location:** `server/internal/app/app.go:511-520` (`isAuthEndpoint`), login flow in `auth_handlers.go`
- **Problem:** Login is limited to 10/min *per IP*. There is no per-account counter, lockout, or credential-stuffing defense across IPs (botnets rotate IPs; mobile carriers put thousands of users behind one CGNAT IP, so per-IP alone both under- and over-blocks). Additionally the reservation endpoints (`/setup/owner/enrollment`, `/register/enrollment`, `/device-links/claim-enrollment`) do cheap DB writes but are only in the 240/min general class (see logical L-15).
- **Recommended fix:** Add a per-username (hashed) failure counter with exponential backoff in the store; classify the three enrollment paths as auth endpoints; return `Retry-After` on 429s.
- **Blocker before production:** No (device-secret requirement already blunts pure password stuffing — an attacker needs a valid device ID + secret pair — but the throttle is cheap defense-in-depth).

## S-4. Admin audit log exposes social-graph metadata (blocks, DM membership) to admins

- **Severity:** Medium–Low (privacy-model consistency)
- **Location:** `server/internal/httpapi/user_control_handlers.go:26,36` (block/unblock audit events carry `target_account_id`); `conversation_handlers.go:202` (member-add events); `GET /api/v1/admin/audit-events`
- **Problem:** The privacy docs promise admins cannot silently observe private relationships. Audit events record who blocked whom and who was added to which conversation, readable by any owner/admin via the audit endpoint. Blocks in particular are a sensitive safety signal (visible retaliation risk if an admin is the blocked party).
- **Recommended fix:** Drop `target_account_id` from block/unblock audit metadata (log only that *an* action occurred, for rate-anomaly review), or hash targets. Review each audit event type against the threat model in `docs/privacy.md`.
- **Blocker before production:** No, but decide before real users generate the data.

## S-5. `containsPlaintextMessageKey` / `isReservedNonProductionKeyPackage` are heuristic guards — document them as such

- **Severity:** Low (informational)
- **Location:** `server/internal/httpapi/api.go:213-286`
- **Problem:** The plaintext-field blocklist (`body`, `text`, `content`, …) and the substring scan of binary key packages for markers like `test-only` are best-effort tripwires, not enforcement: a client can trivially rename a field, and random binary can in principle contain a marker (false-positive rejection of a legit key package is possible, though ~2^-40-ish per marker). Fine as defense-in-depth; must not be relied on as the E2EE boundary.
- **Recommended fix:** Keep, but note in code/docs that the real boundary is client-side encryption; consider requiring a declared `crypto_protocol` allow-list (`mls10-openmls-v1`) at envelope creation the way call metadata already does — today any non-empty string ≤64 chars is accepted (`createMessageEnvelope`), which will let non-MLS test clients write junk protocols into production data.
- **Blocker before production:** Protocol allow-list: recommended yes (cheap, prevents data-quality debt).

## S-6. Session model: 30-day fixed tokens, no rotation, no session inventory

- **Severity:** Low–Medium
- **Location:** `auth_handlers.go` (login/createOwner/register: `time.Now().Add(30*24*time.Hour)`), `sessions` table
- **Problem:** Tokens are single-factor bearer credentials valid 30 days with no sliding expiry, no rotation on privilege-sensitive events other than password change, and no user-visible session list (device list is a proxy but one device can hold several sessions). WS connections are correctly killed at expiry (`ServeWebSocket` expiry timer) and expired rows are pruned. Acceptable v1, but note: `logout-all` keeps the current session's `recent_auth` fresh while others die — good.
- **Recommended fix:** Sliding renewal (reissue when >50% aged) or refresh tokens; per-session listing/revocation UI later.
- **Blocker before production:** No.

## S-7. Blob storage: no serve-time integrity check, keys are the only capability

- **Severity:** Low
- **Location:** `server/internal/uploads/local.go`, `content_handlers.go:194-209` (`serveEncryptedBlob`)
- **Problem:** Blobs are served by DB lookup + `filepath.Base(storageKey)` (path traversal correctly neutralized). The stored SHA-256 is sent as an ETag but never re-verified server-side; a corrupted/truncated file (see logical L-10) is served as-is. Client-side E2EE will detect tampering, but corruption becomes a confusing client-side "decryption failed" instead of a clean server error.
- **Recommended fix:** Verify on-disk size against the DB row before serving (cheap); optionally background-scrub checksums.
- **Blocker before production:** No.

## S-8. Verified non-issues (recorded so the next reviewer doesn't re-derive them)

- XFF handling: rightmost-untrusted-hop selection is correct; header only honored when the direct peer is a trusted proxy; falls back to `parts[0]` only when *every* hop is trusted (self-inflicted config).
- `VACUUM INTO` filename is operator-supplied CLI input, quoted/escaped — not an injection surface.
- SQL throughout uses placeholders; the one `fmt.Sprintf` LIKE pattern is escaped via `escapeLike`.
- Push endpoint validation blocks private/loopback/link-local targets at dial time (rebinding-safe: it dials the resolved IP, not the hostname).
- Usernames are ASCII-only specifically to kill homoglyph impersonation; the reasoning is documented in code.
- Search endpoint deliberately restricts account lookup to exact username match to prevent directory enumeration.
- Setup page CSP, `X-Frame-Options: DENY`, `Cache-Control: no-store` on API responses, HSTS-when-TLS all present.
- Password reset CLI checks file permissions (0600) and probes for exclusive DB access before touching auth state.
- Migration checksums prevent silent drift of applied migrations.

---

**Priority order:** S-1 → S-2 (fuzz or library) → S-5 (protocol allow-list) → S-3 → S-4 → S-6/S-7.
The independent security review already listed in `REMAINING-WORK.md` remains necessary and should cover the Rust FFI, the WS parser (S-2), and the enrollment protocol.
