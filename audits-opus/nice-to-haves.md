# Nice-to-haves

The product as a real user and a real operator would meet it. Nothing here is a
defect — these are gaps between "the engineering is done" and "this feels like a
finished product".

**Two constraints respected throughout.** The board's out-of-scope decisions
(federation, PostgreSQL, S3, NATS, multi-node) are treated as settled and not
reopened. Decision **D06** fixes the sequencing — mobile ships first, desktop
follows, embedding is deferred — and nothing below proposes pulling later phases
forward.

**One observation that shapes this whole file.** Several capabilities are
*fully implemented on the server and unreachable from the client*. Encrypted
backup and recovery (card I18), account data export, and the entire admin API
fall into this category. These are not features to build — they are features to
*connect*. That makes them the highest value-per-hour work available, and they
lead the list below.

---

## High-impact nice-to-haves

Ranked by (user or operator value) ÷ (effort), highest first.

### H1 — Surface the encrypted backup and recovery flow

**Status: server complete, client absent.**

Card I18 delivered capability-based encrypted backup with rollback protection and
no key escrow. `crypto/backup_service.dart` exists. `POST /api/v1/backups`,
`GET /api/v1/backups` and `GET /api/v1/recovery/{token}` all work. The migration
`0023_backup_recovery_tokens.sql` is applied.

The client shows it as a **disabled "Coming soon" tile**
([`ui-issues.md` U18](ui-issues.md#u18)).

**Why this is first.** It is the mitigation for the single worst failure mode in
the product. [`logical-issues.md` L7](logical-issues.md#l7) describes how a
keystore error silently destroys the local database key; without a backup, that is
unrecoverable data loss with no path forward. With one, it is an inconvenience.
The same applies to a lost or broken phone — currently a user with one device who
loses it loses their account access entirely, because sign-in requires a device
secret that lived only on that device
([`ui-issues.md` U3](ui-issues.md#u3)).

**What to build:** a Settings flow that generates the recovery capability, shows
the user-held key **once** with clear "write this down, we cannot recover it for
you" framing, schedules periodic backups, and a restore path reachable from the
connect screen. The cryptography is done; this is UI and scheduling.

### H2 — An admin interface

**Status: server complete, client absent, no operator alternative.**

Four admin endpoints exist and are role-gated:
`GET /api/v1/admin/accounts`, `PATCH /api/v1/admin/accounts/{id}/status`,
`GET /api/v1/admin/audit-events`, `DELETE /api/v1/admin/invites/{id}`.

Nothing in the Flutter client calls any of them. There is no admin CLI. The only
way an owner can suspend an abusive account or read the audit log is `curl` with a
hand-copied bearer token.

**Why it matters.** Every instance has exactly one owner who is a person, usually
not a developer, who is responsible for the people on it. Giving them no tools
means the first moderation incident on any instance is handled by hand or not at
all.

**What to build**, cheapest first:

1. **`messenger-server admin` CLI subcommands** — list accounts, suspend,
   reactivate, revoke invite, tail audit events. Days of work, needs no UI, works
   over SSH, and immediately unblocks operators.
2. **An in-app Admin section** visible to owners and admins, wrapping the same
   four endpoints.
3. **The missing operations**: there is no way to delete a conversation, no bulk
   action, and no way to see instance-level usage (accounts, storage, message
   volume). See [`security-issues.md` S6](security-issues.md#s6) — without any
   creation limits *and* without cleanup tools, a runaway client is unrecoverable
   without direct SQL.

### H3 — Account data export in the client

**Status: server complete, client absent.**

`GET /api/v1/account/export` exists, has a dedicated 5-minute route timeout
(`app.go:214-215`), and is unreachable from the app.

**Why it matters.** GDPR Article 20 (data portability) and Article 15 (access) are
directly relevant for any instance with EU users, and self-hosted operators are
the least equipped to build this themselves. For a privacy-first product, "you can
take your data with you" is also a positioning statement, not just compliance.

**What to build:** a Settings tile that calls the endpoint, saves the result, and
explains plainly what it does and does not contain — encrypted envelopes the user
can decrypt locally, plus metadata, and specifically **not** anything the server
could read. That explanation is itself a demonstration of the architecture.

### H4 — Operational visibility for the person running the server

The metrics surface (`app.go:353-433`) is thoughtful and privacy-safe — request
counts, latency histograms, status classes, realtime connections, no identifiers.
It is off by default and there is nothing else.

An operator today cannot answer: How much disk is left? Is the retention sweeper
keeping up? When did a backup last succeed? Are push deliveries failing? Is the
SQLite writer saturated?

**What to add** (all privacy-safe, no identifiers):

- `veritra_blob_bytes_used` / `_quota_bytes` — capacity planning
- `veritra_expired_messages_pending` — surfaces
  [`logical-issues.md` L5](logical-issues.md#l5) directly
- `veritra_last_backup_success_timestamp` — the number that matters most
- `veritra_push_deliveries_total{result}` — see
  [`performance-issues.md` P10](performance-issues.md#p10)
- `veritra_sqlite_writer_wait_seconds` — the instance's real bottleneck

Plus a **ready-made Grafana dashboard JSON** in `deploy/`. That converts a metrics
endpoint into something a self-hoster will actually use.

Extend `messenger-server doctor` too: it currently reports `storage: ok`. It could
report schema version, disk headroom, blob/row consistency
([`logical-issues.md` L6](logical-issues.md#l6)), last backup, and pending
retention work. One command that answers "is my instance healthy?" is worth a
great deal to this audience.

### H5 — Make the first five minutes work

Covered in detail as [`ui-issues.md` U2](ui-issues.md#u2)–[U4](ui-issues.md#u4),
but it belongs here as a product concern: the current first-run experience is a
prefilled URL that cannot work, a default auth mode that cannot succeed on a fresh
install, and no feedback when either fails.

Beyond the fixes listed there, the product-level additions:

- **A one-screen explanation of the security model** on first launch — password +
  device + no phone number, no plaintext on the server. This is the reason someone
  chose Veritra; say it once, at the moment they are deciding whether to trust it.
- **An operator quickstart that produces a working setup token.** Today
  `deploy/private-messenger.env.example` ships the variable commented out with no
  value and no generation command, which is where
  [`security-issues.md` S1](security-issues.md#s1) starts.
- **A "what happens next" state after owner setup** — the current path ends at a
  browser page that explains it cannot complete setup.

### H6 — Notification quality

`push/push_service.dart` and the two Android services exist, the payload is
correctly generic, and the privacy design is right.

What is missing is everything between "a wake event arrived" and "the user knows
someone messaged them":

- No `POST_NOTIFICATIONS` permission on Android 13+
  ([`security-issues.md` S12](security-issues.md#s12)), so nothing can be
  displayed.
- No notification grouping, no per-conversation channels, no reply-from-
  notification.
- No unread badge on the app icon.
- Per-conversation mute exists (`/notifications` endpoints, wired in the client)
  but there is no global control, no quiet hours, and no per-conversation
  notification *level* (all / mentions / none).

There is a genuine design tension worth stating: the push payload deliberately
carries no sender and no content, so the notification can only say "new encrypted
message" until the client fetches and decrypts. Some products solve this with a
notification service extension that decrypts locally before display. That is a
real feature with real complexity, and it should be a recorded decision rather
than an accident of what was easiest.

---

## Product polish

Smaller things, roughly in order of how often a user would notice them.

**Messaging**

- **Last-message preview in the chat list.** Currently every row's subtitle is
  static text ("Encrypted" / "Private group · Encrypted"). Impossible before the
  crypto gate opens; worth designing now so the row layout does not have to change
  later.
- **Delivery and read state.** Read receipts exist server-side
  (`/read-receipts`, migration `0014_preserve_read_receipts.sql`) and are consumed
  by the client, but no bubble shows sent / delivered / read.
- **Typing indicators.** The server publishes `typing.updated` with a 2-second
  throttle; no screen renders it.
- **Drafts.** A composer's contents are lost on navigation. The board lists this
  under "Later, not release-blocking".
- **Search within a conversation.** Server-side content search is forbidden by
  design, but client-side search over locally decrypted messages is entirely
  compatible with the architecture and is the kind of thing that makes E2EE feel
  like a non-compromise.
- **Jump to a replied-to message.** `reply_to_id` is stored and validated
  server-side.

**Identity and trust**

- **Profiles and avatars.** The board defers these. Worth noting the current
  avatar system (`ui/avatar.dart`, deriving a tint from an account-ID hash across
  five bone temperatures) is genuinely elegant and identity-safe — it may be
  sufficient rather than a placeholder.
- **A contacts or known-people list.** Finding someone requires knowing their
  exact username; `SearchMetadata` matches accounts on exact username only, and
  the reasoning for that (preventing directory enumeration) is sound and
  documented in the SQL. A user-curated contact list would give discoverability
  without weakening it.
- **Verified-device indicators.** The safety-number infrastructure exists (card
  I26) but display is crypto-gated. When it lands, a persistent per-conversation
  verification badge is worth more than a screen users visit once.

**Conversation management**

- **Archive.** Distinct from leave and from mute; the most-requested organisation
  feature in every messenger.
- **Pin to top.**
- **Row actions** — see [`ui-issues.md` U23](ui-issues.md#u23).
- **Group description and avatar.** Groups have a title and nothing else.
- **Invite links with QR.** Invite codes are text; the device-link flow already
  has QR generation (`qr_flutter`) and scanning (`mobile_scanner`), so the
  components exist.

**Trust and transparency**

- **An in-app About / Licences screen** —
  [`ui-issues.md` U13](ui-issues.md#u13). AGPL compliance, store expectations, and
  version reporting for support.
- **A visible privacy statement.** The `README.md` "Security Defaults" list —
  invite-only, no phone numbers, no telemetry, no request-body logging, ciphertext
  only, no server-side search, admins cannot read messages — is the product's
  clearest asset and appears nowhere in the app.
- **A connection-security indicator.** Show which server you are on and that the
  connection is TLS-verified.

---

## Developer experience improvements

**Testing** (detailed in [`production-readiness.md` R6](production-readiness.md#r6))

- Golden tests for the six main screens, light and dark.
- Text-scale and viewport-size matrices.
- A contrast unit test making
  [`ui-issues.md` U1](ui-issues.md#u1) permanently checked.
- Coverage reporting ([R7](production-readiness.md#r7)).
- A seeded-data generator — a `messenger-server seed --accounts 50 --messages 5000`
  command would make every performance finding in
  [`performance-issues.md`](performance-issues.md) measurable in minutes rather
  than reasoned about.

**Local development**

- `scripts/dev.sh` exists. What is missing is a **path to a fully working local
  instance**: because production crypto is gated, a developer cannot complete
  owner setup and therefore cannot exercise most of the app by hand. A documented
  development-only fixture — clearly fenced, never shippable, and blocked by
  `release-readiness.sh` — would transform day-to-day iteration.
- **API documentation.** 66 routes with no OpenAPI spec. `scripts/test-api-contracts.sh`
  and `mobile/test/api_contract_test.dart` already encode the contract; generating
  a spec from them would help third-party client authors, which for an AGPL
  product is a real constituency.
- **A `Makefile` or `justfile`** covering the common loops. `Makefile` exists but
  is minimal.

**Codebase**

- **`AppState` is 1,916 lines** with roughly 60 public methods spanning auth,
  conversations, messages, outbox, sync, push, device links, crypto and blocks. It
  is well organised and clearly written, but it is the single largest maintenance
  risk in the client, and it is the root cause of
  [`performance-issues.md` P5](performance-issues.md#p5) (whole-app rebuilds).
  Splitting it along the seams that already exist — session, conversations,
  messaging, sync — would improve both.
- **`api_client.dart` is 1,142 lines** of hand-written HTTP with a repeated
  request/decode/throw pattern. Generating it from the contract tests, or at least
  extracting the repetition, would shrink it substantially.
- **A repeated linear-scan idiom.** `state.conversations.where((c) => c.id == id).firstOrNull`
  appears in at least four files. A `conversationById` map on `AppState` removes
  all of them ([`performance-issues.md` P6](performance-issues.md#p6)).
- **`storage_error_test.go`, `websocket_contract_test.go` and the fuzz coverage**
  are good models — the Go side is markedly better tested than the Dart side, and
  closing that gap is worth planning explicitly.

**Contribution**

`CONTRIBUTING.md` is short. For an AGPL project actively seeking a security
reviewer and eventual contributors, worth adding:

- how to run the checks without any local toolchain (the Docker fallback is a real
  strength and is under-advertised);
- the crypto gate: what it is, why it exists, and that PRs must not touch it;
- a security disclosure process — `SECURITY.md` exists; make sure it names a
  contact and a response expectation;
- how to add a translation, once [`ui-issues.md` U12](ui-issues.md#u12) lands —
  translation is the easiest way for non-programmers to contribute.

---

## Architecture and stack recommendations

The architecture is sound and the constraints are deliberate. These are
observations, not redesigns.

### Keep

- **SQLite + single node + local blobs.** The right choice for the deployment
  target, and the out-of-scope list defending it is correct. Nothing found in this
  audit argues otherwise.
- **The interface boundaries** (storage, uploads, push, realtime, webrtc, crypto).
  They are real, not nominal, and they are what will make the Phase 2 desktop
  target tractable.
- **Domain logic outside HTTP handlers.** Mostly held; `messaging.Service` is a
  clean example.
- **The fail-closed crypto gate.** Its enforcement needs strengthening
  ([`production-readiness.md` R2](production-readiness.md#r2)); the design is
  right.
- **The Rust crypto core with a C ABI.** Reusing one reviewed core across Flutter
  targets is the correct call, and the D06 rationale for not forking for desktop
  is exactly right.

### Reconsider

**The hand-rolled WebSocket implementation.** Discussed as
[`security-issues.md` S7](security-issues.md#s7). Roughly 300 lines of RFC 6455
frame parsing exposed to a pre-authentication peer, maintained alone. It is
carefully written and no bug was found — but `github.com/coder/websocket` is
zero-dependency, ISC-licensed and Autobahn-conformant, and would remove the
maintenance obligation while satisfying the project's own dependency-review
process. Either adopt it or run Autobahn in CI and name the parser as a review
surface in the I25 brief.

**The single writer connection.** `SetMaxOpenConns(1)` is correct for SQLite, but
it makes every write a global serialisation point — which is why
[`performance-issues.md` P3](performance-issues.md#p3) (quota scans in the write
transaction) and [P7](performance-issues.md#p7) (a write per authenticated
request) matter more than they otherwise would. The fix is not a different
database; it is keeping expensive work out of write transactions. Worth stating as
an explicit architectural rule.

**Sync-event payloads as JSON parsed at read time.** The block filter runs
`json_extract` plus a correlated subquery per row on the hottest read path
([`performance-issues.md` P2](performance-issues.md#p2)). Denormalising the
subject account into a column at write time is the highest-value schema change
available, and it is cheaper before instances have data.

**No structured error taxonomy across the boundary.** The server returns string
codes, the client maps them in a 50-case `switch`, and the two drift silently —
[`ui-issues.md` U15](ui-issues.md#u15) found several unmapped codes including one
that produces actively misleading advice. Generating both sides from one list, or
testing that every `writeError` code has a client case, would make this an
invariant.

### Prepare for Phase 2 without building it

D06 is clear that desktop starts after the mobile release. Two things are cheap
now and expensive later:

- **Keep `flutter_secure_storage` behind an interface.** The board already
  identifies that Windows has no equivalent guarantee. `SecureLocalStore` takes
  the storage as a constructor parameter, which is most of the work already.
- **Do not assume single-instance.** The data-directory lock is server-side; the
  desktop client will need its own answer for multiple windows or instances
  against one local database. Noting the assumption now costs nothing.

---

## Future roadmap ideas

Beyond the board's Phase 1–3. Recorded as options, not recommendations — each
would need a product trigger and, for anything touching crypto, review.

**Strengthens the existing proposition**

- **Multi-account support.** Already on the board's "later" list. Particularly apt
  here: someone on a family instance and a work instance is a realistic user, and
  the architecture (server URL per session) already anticipates it.
- **Passkeys / WebAuthn** as an alternative to password + device secret. On the
  board's later list. Would materially improve the awkwardness described in
  [`ui-issues.md` U3](ui-issues.md#u3).
- **Post-quantum readiness.** The board defers it behind a product trigger, and
  card I27 already tracks the OpenMLS ciphersuite pin. The relevant trigger is
  upstream: when a coordinated OpenMLS release ships a hybrid ciphersuite, the
  question becomes concrete.
- **A stable third-party client API.** AGPL plus a documented API is how a
  protocol acquires alternative clients, which is how it survives its original
  authors. This is mostly documentation, given the contract tests already exist.

**Requires a product decision first**

- **Moderation and reporting.** On the board's later list, correctly gated behind
  a trigger. The hard part is architectural, not political: a report cannot include
  message content, because the server cannot read it. Any design has to be
  client-side attestation, and that has to be thought through before it is built.
- **Message expiry defaults per conversation type.** Retention exists per
  conversation; instance-level defaults would let an operator set policy.
- **Federation.** Explicitly out of scope, and the reasoning holds — MLS across
  administrative domains is a research-grade problem. Worth revisiting only if MIMI
  standardisation produces something implementable.

**Ecosystem**

- **Reproducible builds.** The release pipeline already has `-trimpath`,
  `-buildid=`, `-buildvcs=false`, SBOM, checksums and provenance — most of the way
  there. Publishing a reproducibility recipe would let third parties verify the
  binaries independently, which for this product category is a strong signal.
- **F-Droid.** The natural distribution channel for this audience, and it requires
  reproducible builds and no proprietary dependencies. The FCM dependency is the
  obstacle; the UnifiedPush support already present is exactly the mitigation
  F-Droid expects, so this may be closer than it looks.
- **A public demo instance.** Hard to reconcile with invite-only and a crypto
  gate, but the single most effective way to let someone evaluate the product.

---

## If only three things get done

1. **Ship the backup and recovery UI ([H1](#h1-—-surface-the-encrypted-backup-and-recovery-flow)).** The
   cryptography is finished. It is the only mitigation for the worst failure mode
   in the product, and it is currently displayed to users as "Coming soon" when it
   is in fact built.

2. **Give the operator tools ([H2](#h2--an-admin-interface) and
   [H4](#h4--operational-visibility-for-the-person-running-the-server)).** A
   self-hosted product's operator is a user, and right now they have `curl`, one
   `doctor` command that prints `storage: ok`, and no automated backup. Admin CLI
   subcommands and five more metrics are days of work, not weeks.

3. **Fix the first five minutes ([H5](#h5--make-the-first-five-minutes-work)).**
   The connect screen defaults to a URL that cannot work, in a mode that cannot
   succeed, with no feedback when either fails. Everything else in this audit is
   about a product someone is already using; this is about whether they get that
   far.
