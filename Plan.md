You are Codex acting as a senior/staff-level product engineer, security engineer, mobile engineer, and self-hosting-focused backend architect.

This is the original product brief. It is retained for durable product and
security requirements only. Use `README.md` for implemented capabilities and
`REMAINING-WORK.md` for current status.

Build the initial full-MVP attempt for a new open-source, self-hostable, privacy-first messaging app.

Working name: choose a temporary neutral name such as "Private Messenger" until branding is decided.

Core product idea:
A self-hostable WhatsApp/Signal-style messenger with optional lightweight communities/channels. The product should be easy enough for a non-expert self-hoster to run, privacy-first by default, AGPL-3.0 licensed, mobile-first, and cleanly engineered for long-term maintainability.

The app is not primarily a Discord clone. It may eventually support servers/workspaces/channels/roles, but the first product feeling should be:
- DMs
- private group chats
- WhatsApp-style communities
- optional channels inside communities
- simple roles/permissions
- E2EE everywhere

The project should aim for a full MVP, but do not create a huge fragile prototype. Build in stages, with clear architecture, clean boundaries, tests, and documented assumptions. If something is too large for the first implementation pass, create the interface, docs, test stubs, and a clear TODO/ADR rather than faking insecure behavior.

============================================================
NON-NEGOTIABLE PRODUCT REQUIREMENTS
============================================================

1. License
- Project license: AGPL-3.0-or-later unless research finds a serious blocker.
- Add LICENSE.
- Add NOTICE / THIRD_PARTY_NOTICES.md.
- Track dependency licenses.
- Do not import code without verifying license compatibility.

2. Privacy-first defaults
- Invite-only registration by default.
- No phone-number requirement.
- Email optional, mainly for recovery/notifications if enabled.
- No telemetry.
- No analytics.
- No message-content logs.
- No request-body logs.
- No unnecessary IP retention.
- Minimal operational logs only, local to the instance.
- Configurable retention policy.
- User-controlled export/delete account path.
- Admin must not be able to silently read private messages, DMs, private groups, or private channels.

3. End-to-end encryption everywhere
- All user messages must be E2EE, including DMs, group chats, communities, and channels.
- The server must store ciphertext only for message bodies and attachment contents.
- No plaintext message body should be stored in the server database, server logs, server tests, fixtures, traces, crash reports, or search indexes.
- Do not design or implement custom cryptography.
- Research and choose a proven direction before implementing message crypto.
- Candidate protocols/libraries to compare:
  - MLS / OpenMLS
  - Signal / libsignal
  - Matrix Olm/Megolm or modern Matrix crypto
- Strong initial bias: MLS/OpenMLS for group messaging unless the research finds a blocker.
- Create docs/crypto-research.md and docs/adrs/0002-e2ee-protocol.md before implementing E2EE message flow.
- If the full E2EE implementation is too large, still implement the correct boundaries:
  - crypto package interfaces
  - encrypted envelope types
  - key-package/device model
  - server ciphertext persistence only
  - tests proving the server does not persist plaintext
  - a clearly marked crypto spike or mock that cannot be confused with production crypto

4. Native mobile from day one
- Build a mobile client from the start.
- Preferred client approach: Flutter, unless research strongly recommends another option.
- Must support Android and iOS architecture from day one.
- Prioritize mobile UX over desktop/web.
- Web/desktop can be later, but the server should include a small setup web UI.

5. Self-hosting simplicity
- Primary hosting goal: single executable experience.
- Running one executable should start the server and guide the user through setup.
- Target experience:
  - user downloads binary
  - runs something like ./messenger-server serve
  - opens local setup URL
  - creates first owner account
  - configures instance name, storage path, network mode, HTTPS/push settings if needed
  - invites users
- Also provide Docker Compose.
- Homelab/NAS-friendly.
- Works in LAN/private-network mode.
- Works with Tailscale/ZeroTier-style private networking.
- Works on a public VPS with domain + HTTPS.
- Kubernetes is not a v1 goal.

6. Budget/ease constraints
- Must be cheap to run.
- Optimize for 2-25 users first.
- Should not block 25-150 users.
- Architecture should not prevent 150-1000 users later.
- Avoid mandatory paid SaaS dependencies.
- APNs/FCM are acceptable only for mobile push practicality, and must carry generic encrypted-event notifications only.

7. Feature target for full MVP attempt
Implement or scaffold cleanly toward:
- DMs
- group chats
- communities/workspaces
- channels
- threads/replies
- reactions
- file/image uploads
- 1:1 audio/video calls
- small group calls if feasible to self-host
- push notifications
- search, limited under E2EE constraints
- roles/permissions
- invite links/codes
- message edit/delete
- typing indicators
- read receipts
- disappearing messages
- encrypted backup/recovery
- device linking via QR code

Defer full admin panel and advanced moderation dashboard, but create clean architecture for them later.

8. Search under E2EE
- Search can be limited in v1.
- Do not implement server-side search over message contents.
- Acceptable v1:
  - local client-side search only
  - server-side search only for non-sensitive metadata such as usernames, community names, channel names, and user-visible labels
- Document future option for client-side encrypted search index synced between user devices.

9. Push notifications
- Recommended model:
  - APNs for iOS
  - FCM for Android practical default
  - UnifiedPush-compatible Android option where possible
  - setup-time choice for push mode
- Push payloads must not include message text.
- Prefer not to include sender name.
- Payload should be generic, such as "new encrypted event available".
- Push should be optional.
- Document privacy implications of APNs/FCM.

10. Calls
- Research WebRTC architecture.
- Use self-hostable components only.
- Candidate references:
  - Pion
  - LiveKit
  - Matrix calls where relevant
  - MiroTalk only as reference
- Aim for 1:1 audio/video first.
- Small group calls if feasible without making deployment too heavy.
- Calls should be E2EE where technically feasible.
- If full calls are too large, implement:
  - call signaling model
  - call invitation UX/API
  - WebRTC architecture doc
  - clean interfaces for adding media later

11. Recovery/backups
- No admin recovery of user plaintext.
- Implement or design modern high-privacy recovery:
  - optional encrypted backup
  - backup encrypted client-side before upload
  - recovery phrase or recovery key
  - no server-side plaintext keys
  - no developer/admin backdoor
- Prefer secure device-to-device linking via QR code and verification.
- Document backup threat model.

============================================================
REFERENCE RESEARCH REQUIREMENT
============================================================

Before implementing major features, perform a repo/reference reconnaissance pass.

Create docs/reference-research.md.

Inspect relevant open-source/forkable projects and libraries. For each, document:
- repo / project name
- canonical URL
- current license and SPDX identifier
- whether code reuse is legally compatible with AGPL-3.0-or-later
- stack
- deployment model
- architecture patterns
- data model ideas
- realtime/sync model
- crypto/privacy model
- mobile/client approach
- testing practices
- what to learn from it
- what NOT to copy
- whether forking is worth considering

Projects/libraries to include at minimum:
- Signal / libsignal
- OpenMLS
- Matrix / Synapse / Element ecosystem
- SimpleX Chat
- Mattermost
- Zulip
- Rocket.Chat
- Stoat/Revolt or current successor repos
- PocketBase
- Pion WebRTC
- LiveKit
- Caddy
- UnifiedPush / ntfy
- Optional: MiroTalk

License/reuse rules:
- AGPL/GPL/copyleft code may be studied and may be reused only if compatible with our AGPL-3.0-or-later license and documented.
- MIT/Apache/BSD permissive code may be reused only if attribution and notices are preserved.
- Prefer original clean-room implementation.
- Do not copy large chunks of another app.
- Do not fork by default.
- Forking is allowed only if research proves it saves major time and does not compromise product direction. If considering a fork, create docs/adrs/0001-fork-vs-build.md explaining the tradeoff. Default answer should be build our own.
- Every imported library must be listed in THIRD_PARTY_NOTICES.md or equivalent dependency/license report.

============================================================
PROVISIONAL TECH STACK
============================================================

Codex should research and confirm, but default to this unless a strong reason appears:

Server:
- Go
- modular monolith
- single executable target
- embedded setup web UI
- WebSocket or similar realtime event sync
- REST or typed RPC for command/query API
- SQLite default if suitable
- PostgreSQL adapter designed for later or optionally implemented if not too expensive
- local filesystem object storage for attachments by default
- S3-compatible storage adapter later or scaffolded

Crypto:
- Rust crypto crate/module if using OpenMLS/libsignal or other Rust-first crypto
- clean FFI/bindings for Flutter where needed
- no custom crypto primitives
- crypto interfaces should be isolated from app/domain logic

Mobile:
- Flutter Android/iOS app
- must feel native and mobile-first
- offline-friendly local encrypted storage where feasible
- QR device linking
- local search
- encrypted backup/recovery UX

Deployment:
- single binary first
- Docker Compose second
- public VPS + domain + HTTPS docs
- LAN/private-network mode
- Tailscale/ZeroTier-style private mode docs
- Caddy reverse-proxy/automatic HTTPS docs
- no Kubernetes for v1

Do not create microservices for v1. Use a clean modular monolith.

============================================================
ARCHITECTURE EXPECTATIONS
============================================================

Use a clean, testable architecture.

Recommended repo layout:

/server
  /cmd/messenger-server
  /internal
    /app
    /auth
    /config
    /cryptoapi
    /devices
    /domain
    /events
    /http
    /invites
    /messages
    /presence
    /push
    /realtime
    /retention
    /storage
    /sync
    /uploads
    /webrtc
  /migrations
  /websetup

/mobile
  /app
  /lib
    /features
    /core
    /crypto
    /sync
    /storage
    /ui

/crypto
  /rust
  /docs

/deploy
  /docker-compose.yml
  /caddy
  /systemd

/docs
  /adrs
  reference-research.md
  threat-model.md
  crypto-research.md
  deployment.md
  privacy.md
  api.md
  data-model.md
  recovery.md
  push-notifications.md
  calls.md

/scripts
  dev.sh
  test.sh
  lint.sh

Root files:
- README.md
- AGENTS.md
- LICENSE
- THIRD_PARTY_NOTICES.md
- SECURITY.md
- CONTRIBUTING.md
- Makefile or justfile
- .gitignore
- .editorconfig
- CI config if feasible

Architecture principles:
- Domain logic must not depend directly on HTTP handlers or database details.
- Keep storage behind interfaces.
- Keep crypto behind interfaces.
- Keep push providers behind interfaces.
- Keep WebRTC/call signaling behind interfaces.
- Keep realtime sync protocol versioned.
- Use explicit errors.
- Use context cancellation in Go.
- Avoid cyclic dependencies.
- Avoid global mutable state.
- Make config explicit.
- Use migrations.
- Design for backup/restore.
- Prefer boring, reliable code over clever abstractions.

Suggested backend modules:
- Identity/account module
- Device module
- Invite module
- Community/workspace module
- Conversation/channel module
- Role/permission module
- Message envelope module
- Attachment module
- Realtime sync module
- Presence/typing/read receipt module
- Push notification module
- Retention/disappearing message module
- Backup/recovery module
- Call signaling module

============================================================
DATA MODEL EXPECTATIONS
============================================================

Design data model around encrypted envelopes, not plaintext messages.

Core entities:
- Instance
- Account/User
- Device
- Device key material metadata, but not private keys
- Invite
- Community
- Channel
- Conversation
- Membership
- Role
- Permission
- MessageEnvelope
- AttachmentEnvelope
- Reaction
- ReadReceipt
- TypingEvent
- DisappearingMessagePolicy
- PushSubscription
- BackupBlob
- CallSession
- AuditEvent metadata only, no message contents

MessageEnvelope should include only what the server needs:
- id
- conversation/channel id
- sender account/device id
- ciphertext blob
- crypto protocol metadata
- created timestamp
- edited/deleted marker if needed
- delivery/sync metadata
- size/attachment refs
- no plaintext body

Attachments:
- encrypt client-side before upload
- server stores encrypted blob
- local disk default
- optional S3 adapter design
- quotas
- no server-side thumbnails unless proven safe; prefer client-side thumbnails/previews

============================================================
SECURITY AND PRIVACY REQUIREMENTS
============================================================

Create docs/threat-model.md before or during implementation.

Threat model must cover:
- malicious server admin
- compromised server
- lost user device
- stolen backup
- malicious invited user
- spam/abuse
- metadata leakage
- push notification provider leakage
- attachment leakage
- call signaling leakage
- database theft
- log leakage

Security requirements:
- no custom crypto
- no plaintext message persistence
- no plaintext attachment persistence
- no telemetry
- no analytics
- secure password hashing if passwords are used
- passkey/WebAuthn research or scaffold
- invite-only registration
- rate limiting
- CSRF protection for setup/admin web UI
- secure cookies/session handling if web UI exists
- secure mobile token storage
- local encrypted client storage where feasible
- secrets never logged
- config secrets not committed
- tests that fail if plaintext message fixtures are written to server storage

Identity:
- device-first design
- QR device linking is first-class
- username allowed
- passkeys preferred where feasible
- password fallback allowed
- email optional
- no phone numbers
- account recovery must not give admin plaintext access

Permissions:
- Keep v1 simple but extensible.
- Start with owner/admin/moderator/member concepts.
- Design for custom roles later.
- Per-community and per-channel permissions should be possible.
- Do not overbuild a full Discord permission matrix in the first implementation.

Moderation:
- Admins cannot silently read encrypted content.
- Support metadata-only rate limits and abuse controls.
- Optional user-initiated reports may include voluntarily decrypted content, but do not implement this in a way that creates silent admin access.
- Full moderation dashboard can come later.

============================================================
API / SYNC EXPECTATIONS
============================================================

Design a versioned API.

Acceptable approach:
- REST/OpenAPI for standard commands and queries
- WebSocket for realtime sync
- typed generated clients if feasible

Realtime events:
- new encrypted message envelope
- message edited/deleted marker
- reaction event
- read receipt
- typing event
- membership update
- invite update
- device update
- call signaling event

The realtime sync protocol must be documented in docs/api.md or docs/sync.md.

Offline/mobile behavior:
- mobile app should tolerate network loss
- outgoing queue where feasible
- idempotent message send
- local state cache
- reconnect/resync flow
- conflict handling documented

============================================================
MOBILE APP EXPECTATIONS
============================================================

Build a mobile app shell that can become the real app, not a throwaway demo.

Screens:
- first launch
- connect to self-hosted instance
- accept invite / create account
- create or link device by QR
- chat list
- DM
- group chat
- community/channel list
- message composer
- attachment picker
- reactions
- replies/threads basic UX
- settings
- privacy/recovery settings
- push settings
- call screen placeholder or working 1:1 call if feasible

Mobile architecture:
- feature-based folders
- state management chosen and documented
- typed API client
- local storage abstraction
- crypto abstraction
- sync service abstraction
- push service abstraction
- no business logic buried directly inside UI widgets

============================================================
DEPLOYMENT REQUIREMENTS
============================================================

Single binary mode:
- Implement command such as:
  - messenger-server serve
  - messenger-server init
  - messenger-server migrate
  - messenger-server backup
  - messenger-server restore
  - messenger-server doctor
- First run starts setup wizard.
- Default storage directory should be clear and configurable.
- Provide example config file.
- Provide systemd unit example.
- Provide backup/restore docs.

Docker Compose:
- include server
- include data volume
- include optional Caddy reverse proxy
- include optional PostgreSQL only if chosen/implemented
- keep simple

Networking modes:
- LAN/private mode
- public domain mode
- reverse proxy mode
- Tailscale/ZeroTier private mode

HTTPS:
- document Caddy-based automatic HTTPS path
- support reverse proxy headers safely
- local/LAN mode should still be usable

============================================================
TESTING AND QUALITY BAR
============================================================

From day one:
- unit tests for core domain logic
- integration tests for database/storage
- tests for invite/auth/device flows
- tests for message envelope persistence
- tests proving no plaintext message body is stored server-side
- tests for permissions
- tests for retention/disappearing message policy
- crypto test vectors once crypto choice is made
- lint/format commands
- CI config if feasible
- scripts/test.sh or make test
- scripts/lint.sh or make lint

Quality:
- keep functions small and understandable
- document non-obvious security decisions
- add ADRs for major choices
- avoid speculative abstractions, but keep boundaries clean
- avoid overengineering
- do not implement placeholders that look production-ready but are insecure
- mark incomplete security-sensitive code loudly

Create AGENTS.md with:
- project overview
- architecture rules
- code style
- test commands
- lint commands
- privacy/security non-negotiables
- dependency/license rules
- how to add new modules
- how to run locally

============================================================
FIRST IMPLEMENTATION PLAN
============================================================

Do this in order.

Phase 0: Repository setup
- Create repo structure.
- Add AGPL license.
- Add README with product goal.
- Add AGENTS.md.
- Add basic scripts.
- Add docs folder and ADR folder.
- Add initial CI if feasible.

Phase 1: Research and decisions
- Create docs/reference-research.md.
- Create docs/threat-model.md.
- Create docs/crypto-research.md.
- Create docs/adrs/0001-fork-vs-build.md.
- Create docs/adrs/0002-e2ee-protocol.md.
- Create docs/adrs/0003-database-choice.md.
- Create docs/adrs/0004-mobile-stack.md.
- Create docs/adrs/0005-deployment-model.md.
- After research, choose defaults. If uncertain, pick the safest/simple default and document assumptions.

Phase 2: Backend foundation
- Implement Go server skeleton.
- Implement config loading.
- Implement structured local logging with privacy redaction.
- Implement SQLite storage if chosen.
- Implement migration system.
- Implement setup wizard API/web UI.
- Implement owner account creation.
- Implement invite-only registration.
- Implement auth/session/token foundation.
- Implement device model.
- Implement basic health/doctor endpoints.
- Implement backup/restore skeleton.

Phase 3: Domain model
- Implement users/accounts.
- Implement devices.
- Implement invites.
- Implement communities.
- Implement channels/conversations.
- Implement memberships.
- Implement simple extensible roles/permissions.
- Implement encrypted message envelope persistence.
- Implement encrypted attachment metadata/storage.
- Implement retention/disappearing policy metadata.
- Implement reactions.
- Implement replies/threads metadata.
- Implement read receipts and typing events.

Phase 4: Realtime/sync
- Implement WebSocket or equivalent sync service.
- Implement event fanout for small self-hosted instance.
- Implement idempotent send.
- Implement reconnect/resync.
- Document sync protocol.

Phase 5: Crypto integration
- Implement selected E2EE protocol integration or a clearly marked crypto spike.
- Server must not need plaintext.
- Mobile must own encryption/decryption.
- Add tests preventing plaintext persistence.
- Add crypto test vectors where applicable.
- Document what is production-ready and what is not.

Phase 6: Mobile app
- Implement Flutter app shell.
- Implement connect-to-instance flow.
- Implement invite/account flow.
- Implement QR device linking flow or scaffold.
- Implement chat list.
- Implement DM/group chat UI.
- Implement send/receive encrypted envelope flow.
- Implement reactions/replies/read receipts/typing where feasible.
- Implement settings/privacy/recovery screens.
- Implement local search if feasible, otherwise document limited search.

Phase 7: Attachments
- Implement client-side encrypted upload flow or scaffold.
- Implement local server blob storage.
- Implement quotas.
- Avoid server-side plaintext thumbnails.

Phase 8: Push
- Implement push abstraction.
- Add APNs/FCM/UnifiedPush design docs.
- Implement generic encrypted-event notification scaffolding if full push setup is too heavy.
- No message text or sender name in push payloads.

Phase 9: Calls
- Research Pion/LiveKit.
- Implement self-hosted call signaling model.
- Implement 1:1 call flow if feasible.
- Small group call support if feasible without destroying deployment simplicity.
- Document call E2EE status honestly.

Phase 10: Packaging/deployment
- Single-binary release build.
- Docker Compose.
- systemd example.
- Caddy example.
- LAN/Tailscale/public VPS docs.
- backup/restore docs.
- operational privacy docs.

============================================================
ACCEPTANCE CRITERIA FOR THIS CODEX RUN
============================================================

At the end, produce:
- a repo that builds or clearly documents remaining blockers
- README with quickstart
- AGENTS.md
- AGPL license
- reference research doc
- threat model
- crypto research doc
- ADRs for major choices
- Go server that starts
- setup/init path
- database migrations
- invite/account/device model
- encrypted message envelope model
- realtime sync skeleton or implementation
- Flutter mobile app shell
- Docker Compose
- deployment docs
- tests for core backend flows
- tests ensuring plaintext messages are not persisted server-side
- clear TODO list for incomplete MVP features

Definition of done:
- A developer can clone the repo, run documented commands, and see the server start.
- A developer can run tests.
- A developer can understand the architecture from docs.
- The code does not pretend insecure placeholder crypto is production-ready.
- The server-side model is compatible with E2EE everywhere.
- The self-hosting path remains simple.
- The project remains clean, reusable, and maintainable.

============================================================
IMPORTANT "DO NOT" LIST
============================================================

Do not:
- build a proprietary cloud service
- require Kubernetes
- require PostgreSQL unless research proves SQLite is unsuitable
- require phone numbers
- add telemetry
- log message content
- store plaintext messages
- store plaintext attachments
- implement custom crypto
- silently give admins access to private content
- copy large parts of another project
- fork another project by default
- use server-side message-content search
- make push notifications leak content
- overbuild a Discord-scale permission system for v1
- create many microservices
- bury business logic in UI code
- create fake security
- mark incomplete crypto as production-ready

============================================================
WORKING STYLE
============================================================

Be autonomous but careful.

When uncertain:
- research first
- document assumptions
- choose the simplest safe path
- prefer privacy over convenience
- prefer maintainability over speed
- prefer explicit TODOs over insecure shortcuts

Keep the implementation incremental. After each major step, ensure the repo still builds/tests if possible.

At the end, provide:
- summary of what was implemented
- what remains incomplete
- security/privacy caveats
- how to run locally
- how to test
- recommended next tasks
