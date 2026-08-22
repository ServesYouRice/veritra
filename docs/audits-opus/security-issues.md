# Security issues

**Scope.** This is an application-security review of authentication, secret
handling, abuse prevention, and attack surface. It is **not** a cryptographic
review — MLS group semantics, the OpenMLS integration, the VAP1 payload format,
key-schedule handling and the revocation protocol were not analysed for
cryptographic soundness. That is card **I25** and requires a qualified
independent reviewer. Nothing here should be read as progress against that gate.

**What holds up well.** Worth stating, because the findings below are against a
high baseline:

- Sessions are 256-bit random, stored SHA-256-hashed, never logged.
- Login runs bcrypt against a fixed dummy hash for unknown users
  (`auth.go:56-66`), closing the username-enumeration timing channel — with the
  reasoning written down and the dummy generated eagerly so it cannot be skipped.
- Password comparison, device-secret comparison, setup-token comparison and the
  device-link transcript comparison all use constant-time primitives.
- `X-Forwarded-For` is trusted only when the direct peer is in an explicitly
  configured proxy CIDR, and the walk is right-to-left (`client_identity.go:21-42`)
  — the correct algorithm, which most implementations get wrong.
- Enrollment binds a length-prefixed challenge, the Ed25519 signing key and a
  hash of the key package, verified server-side before any account exists.
- Request bodies are capped at 1 MiB, JSON rejects unknown fields **and**
  trailing documents, and a recursive scan rejects any body containing
  `plaintext`/`body`/`text`/`message`/`content` keys — a real defence-in-depth
  measure for the ciphertext-only invariant.
- The device-link claim token is deliberately carried in a header "to keep it out
  of access logs" (`auth_handlers.go:673`) — exactly the right instinct, which
  makes [S2](#s2) below a consistency gap rather than a blind spot.
- Security headers, loopback-only default binding, a production guard that
  refuses a non-loopback listener without trusted proxies, and a single-writer
  data-directory lock.

| ID | Severity | Title | Area | Blocker |
| --- | --- | --- | --- | --- |
| [S1](#s1) | **High** | Setup token has no entropy floor despite documented promise | Server / setup | **Yes** |
| [S2](#s2) | **High** | Recovery capability token travels in the URL path | Server / backups | **Yes** |
| [S3](#s3) | Medium | Login-backoff table can be flooded to disable per-username backoff | Server / auth | No |
| [S4](#s4) | Medium | bcrypt at cost 10, no Argon2id, no cost migration path | Server / auth | No |
| [S5](#s5) | Medium | Blob quota is enforced only after the body is written to disk | Server / uploads | No |
| [S6](#s6) | Medium | No per-account limits on conversation, community or channel creation | Server / domain | No |
| [S7](#s7) | Medium | Hand-rolled WebSocket framing is an unauthenticated parse surface | Server / realtime | No |
| [S8](#s8) | Medium | No certificate-trust path for self-hosted LAN deployments | Mobile / transport | No |
| [S9](#s9) | Low | Rate-limit table exhaustion refuses new clients | Server / middleware | No |
| [S10](#s10) | Low | Setup-token comparison leaks token length | Server / setup | No |
| [S11](#s11) | Low | 30-day sessions with no rotation or absolute cap | Server / auth | No |
| [S12](#s12) | Low | Missing `POST_NOTIFICATIONS` permission on Android 13+ | Mobile / platform | No |

---

## S1

### Setup token has no entropy floor despite documented promise

**Severity:** High
**Location:** [`server/internal/config/config.go:51`](../../server/internal/config/config.go#L51), [`server/internal/app/app.go:61-64`](../../server/internal/app/app.go#L61-L64), [`server/internal/httpapi/auth_handlers.go:188-196`](../../server/internal/httpapi/auth_handlers.go#L188-L196)

**Problem**

The setup token is read and used with **no validation of length or entropy
anywhere in the codebase**:

```go
SetupToken: os.Getenv("PRIVATE_MESSENGER_SETUP_TOKEN"),        // config.go:51
...
if cfg.Environment == "production" && setupRequired &&
   strings.TrimSpace(cfg.SetupToken) == "" {                   // app.go:61 — non-empty only
    return nil, errors.New("fresh production instance requires PRIVATE_MESSENGER_SETUP_TOKEN")
}
```

`PRIVATE_MESSENGER_SETUP_TOKEN=x` starts a production server successfully.

Meanwhile the documentation promises otherwise:

- `README.md:65` — *"Remote first-owner setup also requires a **high-entropy**
  `PRIVATE_MESSENGER_SETUP_TOKEN`"*
- `docs/operations.md:10` — *"Set … a **high-entropy**
  `PRIVATE_MESSENGER_SETUP_TOKEN` … before the first start"*

Neither statement is enforced by code. The token is a bearer credential that
authorises `POST /api/v1/setup/owner/enrollment` and `POST /api/v1/setup/owner` —
i.e. creating the **owner account** of a fresh instance, the highest-privilege
action the server offers.

Rate limiting does not close the gap. `isAuthEndpoint` (`app.go:594-603`) covers
`/api/v1/setup/owner` at 10/min per IP, and enrollment at 5/min — but those are
per-IP buckets keyed on a salted hash of the client IP, so a distributed attacker
multiplies the budget by their address pool, and a weak token from a small
keyspace (a dictionary word, a date, a project name) falls quickly.

**Why it matters in production**

The exposure window is exactly when an instance is most likely to be discovered:
freshly deployed, DNS just pointed, nobody watching. An attacker who guesses the
token creates the owner account, which grants invite management, admin account
status control, audit-event access and instance naming. The legitimate operator
then finds their own server already claimed.

This is not a theoretical operator-error class. Docker Compose environment files
are copy-pasted, and `deploy/private-messenger.env.example:4` ships the variable
commented out with no value and no generation command — so the operator has to
invent one, unprompted, with nothing telling them how long it needs to be.

The specific failure is **a documented security property that the code does not
enforce**. That is worse than an undocumented weakness, because operators
reasonably rely on the promise.

**Fix**

1. **Validate at startup, fail closed.** In `Config.Load` or `ValidateServe`,
   reject a token shorter than 32 characters when `Environment == "production"`,
   with a message that tells the operator what to do:
   ```
   PRIVATE_MESSENGER_SETUP_TOKEN must be at least 32 characters.
   Generate one with: openssl rand -base64 32
   ```
   Length is a proxy for entropy but a good one here, and it is unambiguous.
2. **Reject obvious placeholders** — the repository's own test values
   (`ci-smoke-setup-token`, `contract-setup-token`, `test-setup-token`) should not
   be accepted in production. The codebase already has this pattern for key
   packages (`isReservedNonProductionKeyPackage`, `api.go:297-303`); mirror it.
3. **Generate one for the operator.** Add
   `messenger-server generate-setup-token` that prints a 32-byte base64 value, and
   reference it from `README.md`, `docs/operations.md`,
   `deploy/private-messenger.env.example` and the systemd unit comment.
4. **Bound the window.** Consider making the token single-use — consumed on the
   first successful `createOwner` — and/or valid only for the first N minutes of
   uptime. The board already describes I21's "one-time setup-secret lifecycle";
   this would make that literal.
5. **Tighten the rate limit** on setup endpoints specifically. They are used once
   in an instance's life; 5/min is generous. 3 attempts per hour per instance
   (not per IP) would make brute force infeasible regardless of token quality.

**Blocker:** **Yes.** A documented security guarantee that is not enforced,
guarding the highest-privilege operation on the server.

**Related risks**

- The tokenless fallback (`setupAuthorized` → loopback-only) is correctly gated:
  `app.go:61` refuses to start a fresh production instance without a token, so
  the loopback path cannot be reached remotely in production. That reasoning is
  sound and should be preserved by any fix.
- See [S10](#s10) for the length-comparison side channel in the same function.

---

## S2

### Recovery capability token travels in the URL path

**Severity:** High
**Location:** [`server/internal/httpapi/api.go:58`](../../server/internal/httpapi/api.go#L58), handler at [`server/internal/httpapi/content_handlers.go:190-203`](../../server/internal/httpapi/content_handlers.go#L190-L203)

**Problem**

```go
mux.HandleFunc("GET /api/v1/recovery/{token}", a.recoverBackup)
```

The route is **unauthenticated by design** — the 32-byte token *is* the
capability, which is the correct model for recovery (there is no session to
authenticate with when you are recovering). The token itself is strong: 32 random
bytes, compared by SHA-256 hash lookup, unguessable.

The problem is placement. A URL path is the single most-logged field in the
entire HTTP stack:

- **Reverse-proxy access logs.** `deploy/caddy/Caddyfile` fronts the server;
  Caddy's access logs include the full URI by default, so the capability lands in
  plaintext on disk with normal log retention and normal log-shipping.
- **`Referer` headers** on any subsequent navigation.
- **Browser history and clipboard**, if a recovery link is ever opened in a
  browser or shared.
- **Container log drivers** (`json-file`, 10 MB × 3 configured) and any log
  aggregation an operator adds.
- The server's own `requestLogger` is safe — it logs `routeClass(r.URL.Path)`
  which collapses to a pattern (`app.go:472-497`) — but note `/api/v1/recovery/`
  is **not** in `routeClass`'s switch, so it falls to `default: return path` and
  the full token **is written to the server's own structured log**.

That last point makes this concrete rather than hypothetical: the token is logged
by Veritra itself, on an instance whose stated policy is "no message-content
logs, no request-body logging".

The codebase already knows better. Fifty lines away:

```go
case parts[1] == "claim-status" && r.Method == http.MethodGet:
    // The claim token is sent via header to keep it out of access logs.
    claimToken := strings.TrimSpace(r.Header.Get("X-Veritra-Claim-Token"))
```

Same threat, same class of credential, opposite decision.

**Why it matters in production**

The recovery token decrypts nothing on its own — the backup blob is
independently encrypted with a user-held key — so this is not a direct
plaintext compromise. But it is a capability to **download the encrypted backup
blob**, which yields an offline attack target, size metadata, and a copy of the
user's state that the threat model says the server operator should not be able to
hand out. Anyone with log access — an operator, a log-shipping vendor, an
attacker who reads logs rather than the database — obtains it.

A privacy product that goes to the trouble of hashing session tokens at rest and
of moving one capability into a header should not put a sibling capability in a
path.

**Fix**

1. **Move the token to a header**, exactly as the claim token already is:
   `GET /api/v1/recovery` with `X-Veritra-Recovery-Token: <base64url>`. Keep the
   32-byte length check and the SHA-256 lookup unchanged.
2. **Or accept it in a POST body** if a header is inconvenient for the client —
   bodies are already excluded from logging by policy.
3. **Add `/api/v1/recovery/` to `routeClass`** regardless, so no future variant
   can leak a path segment into the server's own logs. While there, audit the
   `default:` branch for any other route whose path contains a secret.
4. **Add a regression test** asserting no request log line contains a value from a
   defined set of secret-shaped inputs. That converts a rule into an invariant.
5. **Add rate limiting.** `/api/v1/recovery/{token}` is not in `isAuthEndpoint`,
   so it gets only the 240/min general bucket. It should be treated as an auth
   endpoint.

**Blocker:** **Yes.** A capability credential is written to logs by the server's
own logger, contradicting a stated privacy boundary.

**Related risks**

- Same argument applies to the `veritra://device-link?code=` URI
  (`api.go:363`) if it is ever surfaced as a clickable link — see
  [`ui-issues.md` U14](ui-issues.md#u14).
- The backup blob served here is streamed via `http.ServeContent`, which supports
  Range requests — so a leaked token also allows repeated partial fetches, each
  of which triggers a full re-hash of the blob (see
  [`performance-issues.md` P1](performance-issues.md#p1)). The two findings
  compound into a cheap amplification primitive.

---

## S3

### Login-backoff table can be flooded to disable per-username backoff

**Severity:** Medium
**Location:** [`server/internal/httpapi/login_backoff.go:55-84`](../../server/internal/httpapi/login_backoff.go#L55-L84)

**Problem**

The per-username backoff keeps at most 32,768 entries:

```go
if len(backoff.byID) >= maxLoginBackoffEntries {
    for existingKey, entry := range backoff.byID {
        if !entry.expiresAt.After(now) { delete(backoff.byID, existingKey) }
    }
}
entry := backoff.byID[key]
entry.failures++
...
if len(backoff.byID) < maxLoginBackoffEntries || backoff.byID[key].failures > 0 {
    backoff.byID[key] = entry
}
```

Two properties combine badly. The eviction pass removes only **already-expired**
entries, and entries live 15 minutes. And the final guard reads
`backoff.byID[key].failures` — the *stored* value, which is `0` for a key not yet
present — so when the table is full, **a new identity is never inserted**.

So: an attacker submits failed logins for 32,768 distinct non-existent usernames
within a 15-minute window. The table fills with unexpirable entries. From that
point, any username **without an existing entry** — including every legitimate
user who has not recently failed a login — gets `RetryAfter() == 0` forever,
because their entry can never be created.

Per-username backoff is then off, leaving only the per-IP auth limit of 10/min
(`app.go:71`), which a distributed source defeats by definition.

Cost to the attacker: 32,768 requests, throttled per IP at 10/min, so a modest
address pool over a few minutes. There is also no background sweeper — unlike the
rate limiter, which has `cleanupLoop` (`app.go:533-550`) — so the table only ever
shrinks when `Failed()` is called and finds expired rows.

**Why it matters in production**

Backoff is the only thing between a leaked-password-list attack and the bcrypt
verifier. Turning it off does not by itself break authentication — the password,
the device ID and the device secret are all still required, which is a genuinely
strong position — but it removes a defence the design clearly intends to have,
and it does so silently, with no metric and no log line.

**Fix**

1. **Add a sweeper.** Copy the `cleanupLoop` pattern: a ticker that drops expired
   entries every minute, so the table cannot fill with stale rows.
2. **Fix the insertion guard.** `backoff.byID[key].failures > 0` should be
   `_, exists := backoff.byID[key]` — the intent is clearly "keep updating
   existing entries even when full", and the current expression never matches for
   a new key.
3. **Evict when full**, rather than declining to insert: drop the entry with the
   earliest `expiresAt` and admit the new one. Never let table pressure translate
   into a disabled control.
4. **Raise the ceiling** and/or make it configurable — 32,768 × ~64 bytes is
   about 2 MB, so an order of magnitude more is affordable.
5. **Emit a metric** for backoff-table occupancy and for evictions-due-to-pressure.
   Silent degradation of a security control is the part that makes this worth
   fixing.

**Blocker:** No — three factors are still required — but it is a real bypass of an
intended control.

**Related risks** — [S9](#s9) is the same class in the rate limiter, with the
opposite failure direction (fail-closed rather than fail-open).

---

## S4

### bcrypt at cost 10, no Argon2id, no cost migration path

**Severity:** Medium
**Location:** [`server/internal/auth/auth.go:29`](../../server/internal/auth/auth.go#L29)

**Problem**

```go
hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
```

`bcrypt.DefaultCost` is 10 — roughly 60–100 ms on a modern core. That value has
been the library default since 2011 and has not tracked hardware.

Current guidance (OWASP Password Storage Cheat Sheet, NIST SP 800-63B) puts
Argon2id first and bcrypt at **cost ≥ 12** where bcrypt is retained. Cost 12 is
4× the work of cost 10.

There is also no upgrade path: the stored hash carries its cost, and nothing
re-hashes on successful login, so raising the constant would only affect new
passwords and existing accounts would stay at cost 10 permanently.

Mitigating context, which is genuine: a password alone is not sufficient to
authenticate. `login` also requires `device_id` and a 256-bit `device_secret`
(`auth_handlers.go:226`). An attacker with the password database and no device
secret cannot log in. So the realistic threat is credential reuse against other
services after a database compromise, not direct account takeover.

Also correct and worth noting: the 72-byte bcrypt truncation is explicitly
rejected rather than silently accepted (`auth.go:22-28`), with the reasoning
written down. That is better than most implementations manage.

**Why it matters in production**

Self-hosted deployments are single-node with the database on local disk and no
managed backup encryption. A stolen `private-messenger.db` — from a snapshot, a
misconfigured backup, a decommissioned VPS — is the realistic compromise for this
architecture, and at cost 10 the weaker passwords in it fall to commodity GPU
cracking. Users reuse passwords; the harm lands on their other accounts.

**Fix**

1. **Raise the cost to 12** for new hashes. One constant.
2. **Add transparent rehash-on-login.** After `VerifyPassword` succeeds, call
   `bcrypt.Cost(hash)`; if it is below the target, re-hash the supplied plaintext
   and update the row. This is the standard migration and it needs no user action.
   `ChangePassword` already exists as a template for the write path.
3. **Consider Argon2id** (`golang.org/x/crypto/argon2`, already an indirect
   dependency via `x/crypto`) with a stored parameter prefix so parameters can
   evolve. Larger change; schedule it deliberately, not as part of a fix.
4. **Make the cost configurable** so an operator on constrained hardware (a Pi,
   a small VPS) can tune it, with a documented floor. This matters because
   `login` runs bcrypt on *every* attempt including failures — see the dummy-hash
   path — so cost directly sets the per-request CPU budget under credential
   stuffing.
5. Record the decision in the **I25** brief either way: "bcrypt cost N, chosen
   because …" is exactly the kind of thing a reviewer will ask about.

**Blocker:** No.

---

## S5

### Blob quota is enforced only after the body is written to disk

**Severity:** Medium
**Location:** [`server/internal/httpapi/content_handlers.go:47-73`](../../server/internal/httpapi/content_handlers.go#L47-L73), quota at [`server/internal/storage/content_store.go:611-628`](../../server/internal/storage/content_store.go#L611-L628)

**Problem**

The upload path is: stream the body to disk, hash it, then check the quota.

```go
storageKey, sha, size, err := a.Blobs.PutEncryptedBlob(r.Context(), http.MaxBytesReader(w, r.Body, 50<<20))
...
attachment, err := a.Store.CreateAttachmentEnvelope(...)   // enforceBlobQuota runs HERE
if err != nil {
    a.cleanupUncommittedBlob(r.Context(), storageKey)      // then delete it again
```

An account already at its 1 GiB quota can therefore still cause **unbounded disk
write churn**: every rejected upload writes up to 50 MB (100 MB for backups),
`fsync`s it, hashes it, and deletes it. The general rate limit allows 240
requests/minute, so a single authenticated account can drive on the order of
gigabytes per minute of write-and-delete against the data volume — with a 100%
rejection rate and no quota violation ever recorded.

The cleanup path is well built (`cleanupUncommittedBlob` uses
`context.WithoutCancel` and falls back to the durable deletion queue), so this is
not a leak. It is a cost amplification: a cheap request produces expensive I/O.

**Why it matters in production**

Self-hosted instances run on small volumes with limited IOPS. Sustained
write-then-delete at that rate degrades SQLite write latency for every other user
(single writer connection, same disk), accelerates SSD wear, and can fill the
volume transiently between write and cleanup. Nothing in the metrics surface would
show why.

**Fix**

1. **Pre-check before streaming.** Read `Content-Length`, and if
   `currentUsage + declaredLength` already exceeds the quota, return
   `507 storage_quota_exceeded` before opening the temp file. Keep the post-write
   check as the authoritative one — `Content-Length` is client-supplied — but the
   cheap check rejects the honest-and-full case, which is the common one.
2. **Rate-limit uploads specifically.** `isAuthEndpoint` and
   `isEnrollmentEndpoint` already establish per-endpoint classes; add an upload
   class with a much lower ceiling (a handful per minute), keyed on account rather
   than IP so it survives address rotation.
3. **Count rejections.** A metric for quota-rejected uploads per account turns
   this from invisible into diagnosable.
4. **Make the quota configurable** — see [S6](#s6); the hardcoded 1 GiB / 10 GiB
   is a separate problem with the same root.

**Blocker:** No.

**Related risks** — `enforceBlobQuota` itself is expensive (two unindexed `SUM()`
scans inside the write transaction); see
[`performance-issues.md` P3](performance-issues.md#p3). Every rejected upload pays
that cost too, which makes the amplification worse than the disk I/O alone
suggests.

---

## S6

### No per-account limits on conversation, community or channel creation

**Severity:** Medium
**Location:** [`server/internal/httpapi/conversation_handlers.go:17-32`](../../server/internal/httpapi/conversation_handlers.go#L17-L32) (`createCommunity`), `:86-112` (channel creation), `:125-154` (`createConversation`)

**Problem**

Any authenticated account may create unlimited communities, unlimited channels
within them, and unlimited conversations. The only bounds are:

- `validDisplayName` — a name must be 1–64 characters;
- `len(input.MemberAccountIDs) > 100` in `CreateConversation`
  (`community_store.go:684`) — a per-request cap, not a total;
- the global 240 requests/minute per-IP rate limit.

There is no per-account ceiling, no quota, and no rate class for creation
endpoints. Each created row also fans out: conversations create memberships,
memberships appear in `ListSyncEvents`' membership join, and every member's sync
query gets more rows to scan.

Registration is invite-only by default, which raises the bar to obtaining one
invite. But `createInvite` allows `MaxUses` up to 10,000 (`auth_handlers.go:448`),
so a single leaked or over-provisioned invite yields many accounts.

**Why it matters in production**

The realistic scenario is not a determined attacker but a buggy client or a
runaway script: a retry loop on `createConversation` fills the database with
thousands of empty conversations. The victim's chat list becomes unusable, sync
queries slow for everyone in the affected conversations, and there is no admin
tool to bulk-delete them — `/api/v1/admin/*` covers account status, audit events
and invite revocation, and nothing else.

For a single-node SQLite deployment with one writer connection, unbounded row
creation by any authenticated user is a capacity risk regardless of intent.

**Fix**

1. **Add per-account ceilings** with sensible defaults: e.g. 1,000 conversations,
   50 communities, 200 channels per community. Return `409` with a distinct code.
   These are high enough never to be hit by a real user and low enough to stop a
   loop.
2. **Add a creation rate class** to the rate limiter alongside `isAuthEndpoint`
   and `isEnrollmentEndpoint` — a handful per minute is ample.
3. **Make the limits configurable**, together with the blob quota from
   [S5](#s5). A hardcoded 1 GiB per account and 10 GiB per instance
   (`content_store.go:612-613`) is wrong in both directions: too small for a
   family instance on a 4 TB NAS, too large for a 20 GB VPS. Add
   `PRIVATE_MESSENGER_ACCOUNT_BLOB_QUOTA_BYTES`,
   `PRIVATE_MESSENGER_INSTANCE_BLOB_QUOTA_BYTES` and the conversation ceilings,
   documented in `docs/operations.md`.
4. **Give admins a cleanup tool** — see [nice-to-haves.md](nice-to-haves.md); the
   admin API has no conversation-level operations at all.

**Blocker:** No.

---

## S7

### Hand-rolled WebSocket framing is an unauthenticated parse surface

**Severity:** Medium (architectural)
**Location:** [`server/internal/realtime/websocket.go`](../../server/internal/realtime/websocket.go) — 313 lines implementing RFC 6455 directly

**Problem**

The server implements the WebSocket protocol from scratch on top of
`http.Hijacker`: handshake, `Sec-WebSocket-Accept`, frame parsing, masking,
fragmentation, control frames, close-code validation and UTF-8 validation.

To its credit, the implementation is careful and clearly written by someone who
read the RFC. It correctly rejects unmasked client frames (§5.1), rejects
reserved bits, rejects fragmented control frames, rejects non-minimal length
encodings (`length < 126` for a 16-bit header, `<= 65535` for 64-bit), rejects
the high bit of a 64-bit length, caps frames at 1 MiB, caps accumulated
fragments, validates close codes against the permitted ranges, and validates
UTF-8 on text frames and close reasons. The keepalive design is right —
server-initiated pings with a read deadline refreshed on any frame, so a
half-open peer is reaped rather than pinning a goroutine. The board records
adversarial and fuzz coverage under card I23.

The concern is not a specific bug found here — none was — but the standing
position: this is a **binary parser exposed to a pre-authentication network
peer**, maintained by this project alone, against a specification with a long
history of subtle implementation vulnerabilities (masking errors, length
sign-extension, fragmentation state confusion, compression-extension issues).

The specific costs: no upstream security advisories to subscribe to, no Autobahn
test-suite conformance run in CI, and every future maintainer inherits the
obligation to re-derive RFC 6455 correctness.

**Why it matters in production**

The Go ecosystem has two well-maintained implementations —
`github.com/coder/websocket` (formerly nhooyr, zero-dependency, permissively
licensed, Autobahn-tested) and `gorilla/websocket`. Either would remove ~300
lines of security-relevant code, come with upstream advisories, and satisfy the
project's own dependency review process, which is already rigorous
(`THIRD_PARTY_NOTICES.md`, `scripts/license-check.sh`, Dependabot).

**Fix**

Pick one:

1. **Adopt `github.com/coder/websocket`.** Zero dependencies, ISC-licensed,
   Autobahn-conformant. The `Hub`/`Client` abstraction is already clean, so the
   change is confined to `websocket.go`. This also delivers
   [`logical-issues.md` L17](logical-issues.md#l17) (proper close frames) for
   free.
2. **Or keep it and prove it.** Run the **Autobahn TestSuite** in CI against the
   handler, add a `go-fuzz`/native fuzz target for `drainClientFrames`, and
   document the decision in the **I25** review brief with the rationale for not
   using a library. The frame parser should be an explicitly named review surface;
   the current brief lists server "MLS, message, attachment, backup, revocation,
   push, and call paths" but not the WebSocket framing.

Option 1 is the smaller total cost. Option 2 is legitimate if the zero-dependency
posture is deliberate — but then the conformance evidence has to exist.

**Blocker:** No — and this needs approval as a dependency change per `AGENTS.md`.

---

## S8

### No certificate-trust path for self-hosted LAN deployments

**Severity:** Medium
**Location:** [`mobile/lib/core/api_client.dart:9-13`](../../mobile/lib/core/api_client.dart#L9-L13); `usesCleartextTraffic="false"` in `AndroidManifest.xml`; no ATS exception in `Info.plist`

**Problem**

The client uses a bare `HttpClient()` with no `badCertificateCallback`, no
certificate pinning, and no user-facing trust decision. Combined with cleartext
being blocked on both platforms, the app can connect **only** to a server
presenting a certificate chaining to a platform-trusted root.

This produces two gaps at opposite ends:

- **No pinning.** For a security-focused messenger, a compromised or coerced
  public CA can transparently intercept the connection. TLS interception yields
  metadata (who talks to whom, when, message sizes, call timing) — which the
  threat model already concedes the server sees, so the marginal loss is bounded,
  but a pin is the standard mitigation and is absent.
- **No trust path for LAN.** A self-hosted instance at `https://192.168.1.10:8443`
  or `https://veritra.home.arpa` cannot obtain a public certificate. There is no
  way to trust its certificate from the app, and no error message explaining why.

**Why it matters in production**

"Self-hostable" is the first word of the product description, and the roadmap
names *"a self-hosted internal-network deployment"* as an explicit Phase 2
target. Today that deployment cannot be reached by the client at all, and the
failure is a raw socket error.

**Fix**

1. **Decide and document the LAN story.** Options, in order of preference:
   - Document the Caddy internal-CA path (`tls internal`), have the operator
     distribute the CA certificate, and rely on OS-level trust. Zero client code,
     and it is the honest answer for a self-hosted product.
   - Or add an explicit trust-on-first-use flow: show the certificate SHA-256
     fingerprint, require the user to confirm it out of band, and pin it
     thereafter. Deliberately awkward, which is correct for this decision.
   Do not silently accept invalid certificates under any circumstances.
2. **Add optional pinning for the common case.** Once a server is configured,
   record its certificate's public-key hash and warn loudly on change. This is
   cheap and gives real protection against CA compromise without breaking
   legitimate rotation (warn, do not hard-fail).
3. **Surface TLS failures distinctly** in `ApiException`/`describeError` so
   "certificate not trusted" does not read the same as "no network" — see
   [`ui-issues.md` U4](ui-issues.md#u4).
4. Add the decision to `docs/operations.md` alongside the existing TLS-at-the-proxy
   guidance.

**Blocker:** No — but it blocks a stated Phase 2 use case.

---

## S9

### Rate-limit table exhaustion refuses new clients

**Severity:** Low
**Location:** [`server/internal/app/app.go:560-571`](../../server/internal/app/app.go#L560-L571)

**Problem**

```go
b, ok := rl.buckets[key]
if !ok || b.reset.Before(now) {
    if len(rl.buckets) >= maxRateLimitEntries && !ok {
        rl.mu.Unlock()
        w.Header().Set("Retry-After", "60")
        http.Error(w, "rate limited", http.StatusTooManyRequests)
        return
    }
    ...
}
```

When the bucket map reaches 65,536 entries, every client **without an existing
bucket** receives a 429. Buckets last one minute and `cleanupLoop` sweeps every
minute, so filling the table requires ~65,536 distinct source IPs within a
one-minute window.

This is the deliberate fail-closed choice, and for a rate limiter it is the
defensible one — the alternative (unbounded map growth) is worse. The observation
is that it converts a memory-exhaustion attempt into a **service denial for
legitimate new clients**, and that the threshold is reachable for an IPv6-facing
deployment where a single /64 provides effectively unlimited source addresses at
no cost to the attacker.

**Why it matters in production**

Existing clients with live buckets keep working, so this is partial rather than
total. But new connections — including a user opening the app for the first time
that minute — are refused, and nothing logs that the table is saturated, so an
operator sees "users report 429s" with no explanation.

**Fix**

1. **Key IPv6 sources by /64, not by full address.** A single /64 is one customer
   allocation; treating 2^64 addresses as 2^64 distinct clients is what makes the
   table cheap to fill. This is the substantive fix and it is a few lines in
   `remoteHash`.
2. **Log and meter saturation.** A warn-level log (rate-limited itself) and a
   gauge for bucket-map occupancy make the condition visible.
3. **Evict rather than refuse**: drop the oldest-reset bucket to admit a new
   client, so a legitimate user is never turned away by table pressure alone.
4. Raise `maxRateLimitEntries` — 65,536 small structs is well under a megabyte.

**Blocker:** No.

**Related risks** — [S3](#s3) is the same class in the login backoff, failing in
the opposite (open) direction. Both would benefit from the same eviction policy.

---

## S10

### Setup-token comparison leaks token length

**Severity:** Low
**Location:** [`server/internal/httpapi/auth_handlers.go:189-193`](../../server/internal/httpapi/auth_handlers.go#L189-L193)

**Problem**

```go
provided := r.Header.Get("X-Veritra-Setup-Token")
return len(provided) == len(a.SetupToken) &&
    subtle.ConstantTimeCompare([]byte(provided), []byte(a.SetupToken)) == 1
```

The content comparison is constant-time, which is right. But the length check
short-circuits before it, so a mismatched length returns without performing the
compare — a timing difference that reveals the token's exact length.

`subtle.ConstantTimeCompare` already returns 0 for unequal lengths, so the guard
adds nothing but the leak.

**Why it matters in production**

Small. Knowing the length narrows a brute-force keyspace only marginally, and
[S1](#s1) — no entropy floor at all — is by far the larger problem in the same
function. It is worth fixing because it is one line and because leaving a
timing side channel next to a constant-time comparison invites a reviewer to
question the rest.

**Fix**

Compare hashes of both values, which is length-independent and idiomatic:

```go
providedSum := sha256.Sum256([]byte(provided))
expectedSum := sha256.Sum256([]byte(a.SetupToken))
return subtle.ConstantTimeCompare(providedSum[:], expectedSum[:]) == 1
```

The same pattern is already used elsewhere for device secrets
(`auth.HashToken` then `ConstantTimeCompare`), so this also makes the file
internally consistent.

**Blocker:** No.

---

## S11

### 30-day sessions with no rotation or absolute cap

**Severity:** Low
**Location:** [`server/internal/httpapi/auth_handlers.go:241`](../../server/internal/httpapi/auth_handlers.go#L241), `:170`, `:683`

**Problem**

Every session is created with a flat 30-day expiry:

```go
a.Store.CreateSession(r.Context(), tokenHash, record.AccountID, record.DeviceID,
    time.Now().UTC().Add(30*24*time.Hour))
```

There is no token rotation, no sliding-window refresh, and no absolute lifetime
beyond the 30 days. A stolen bearer token is valid for up to a month unless the
user notices and revokes the device or runs logout-all.

Mitigations that do exist and are good: tokens are stored hashed;
`withRecentAuth` requires re-authentication within 5 minutes for every
destructive operation; `logout-all` and per-device revocation exist and are
surfaced in the UI; and the WebSocket carries a session-expiry timer that closes
the socket at expiry (`websocket.go:77`).

**Why it matters in production**

For a messenger, 30 days is a reasonable trade — forcing re-auth more often on a
device that also holds a device secret buys little. The gap is the absence of any
signal: there is no session list, no "last used" per session, no "new sign-in on
device X" notification. `MarkDeviceSeen` records `last_seen_at` per device and
`GET /api/v1/devices/me` returns it, so the data exists — it is simply not turned
into a security signal.

**Fix**

1. **Rotate on use.** Issue a fresh token periodically (e.g. every 7 days of
   activity) and expire the previous one after a short grace period. Bounds the
   value of a captured token without touching the user experience.
2. **Surface sessions.** The Devices screen already lists devices with
   `last_seen_at`; add the active-session count and creation time per device, and
   make revocation from that list obvious. Users detect compromise far more
   reliably than servers do.
3. **Notify on new sign-in** — a sync event to the account's other devices when a
   session is created. The event infrastructure and per-account fan-out already
   exist, and `device.updated` is an existing precedent.
4. Add an absolute cap (e.g. 90 days) that no rotation can extend.

**Blocker:** No.

---

## S12

### Missing `POST_NOTIFICATIONS` permission on Android 13+

**Severity:** Low (functional impact, security-adjacent)
**Location:** [`mobile/android/app/src/main/AndroidManifest.xml`](../../mobile/android/app/src/main/AndroidManifest.xml)

**Problem**

The manifest declares `INTERNET`, `CAMERA`, `RECORD_AUDIO`,
`MODIFY_AUDIO_SETTINGS` and `BLUETOOTH_CONNECT`. It does **not** declare
`android.permission.POST_NOTIFICATIONS`, which Android 13 (API 33) made a
runtime permission required to display any notification.

Two push service declarations are present (`VeritraPushService` for UnifiedPush,
`VeritraFirebaseMessagingService` for FCM), so the app does receive wake events —
it simply cannot show anything to the user about them on Android 13+ without the
permission and a runtime request.

**Why it matters in production**

Card **I24** step 4 requires testing "FCM/APNs background wake" on physical
devices. That test will show the wake arriving and catch-up running, while no
notification appears — a result easy to misdiagnose as a push-delivery failure
when it is a manifest omission.

More broadly: a messenger that cannot notify is a messenger users stop opening.

**Fix**

1. Add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`.
2. Request it at runtime at an appropriate moment — after the first successful
   sign-in, not at cold start — with a short explanation of what will and will not
   be shown. That explanation is a genuine selling point here: the push payload is
   generic by design and carries no sender or content
   (`docs/board.md`: *"Push carries only `new_encrypted_event_available`"*).
3. Handle denial gracefully: the app still works, catch-up still runs, and
   Settings should show the state and offer a link to system settings. The
   existing "Push provider" tile is the natural home.
4. Verify the iOS counterpart — `UNUserNotificationCenter` authorisation must be
   requested explicitly there too, and `Info.plist` currently declares only the
   `remote-notification` background mode. See
   [`production-readiness.md` R13](production-readiness.md#r13).

**Blocker:** No — but it will confound I24's push verification if not fixed
first.

---

# Summary

**Two findings should block release:**

- **[S1](#s1)** — the setup token has no entropy floor while two documents promise
  it does. It guards owner creation on a fresh instance. One validation in
  `Config.Load` closes it.
- **[S2](#s2)** — the recovery capability is written into the URL path and, because
  `routeClass` has no case for it, into the server's own request log. Move it to a
  header, as the device-link claim token already is.

**Neither is a cryptographic finding.** The crypto boundary was not audited here
and remains gated behind card I25.

**The rest are hardening.** [S3](#s3)–[S6](#s6) are real bypasses or missing
limits worth a maintenance cycle; [S7](#s7) is a standing architectural position
that deserves an explicit decision rather than a default; [S8](#s8) blocks a
stated Phase 2 use case; [S9](#s9)–[S12](#s12) are small.

**Two things to add to the I25 review brief**, which currently does not name
them:

1. The WebSocket frame parser (`realtime/websocket.go`) as an explicit review
   surface — it is a pre-auth binary parser and is not in the brief's list.
2. The password-hashing parameters and their migration path ([S4](#s4)), recorded
   with rationale.

And one to correct: the brief lists "wrong local database key" as a mandatory
failure case. [`logical-issues.md` L7](logical-issues.md#l7) identifies the
mechanism that produces one — `resetOnError: true` — and it fails open rather
than closed, contrary to decision **D01**.
