# Veritra implementation record

This is the single authoritative record for active implementation work,
completed work, release evidence, and the independent-review handoff.
Historical source material remains read-only under `archive/2026-07-26/`.

## Current status

**NO-GO:** production crypto remains fail-closed.

**Active local work: I28, the K2 · Bone visual rebuild.** It is the only card
that can move without external inputs, and it is the current priority.

Every other remaining card is externally blocked. They need signing
credentials, supported physical Android and iOS devices, macOS for the iOS
build, an operator-controlled TURN deployment, push-provider credentials, a
coordinated upstream OpenMLS/HPKE security update, and an independent security
reviewer. Do not remove `PM_CRYPTO_UNAVAILABLE` or replace
`UnavailableCryptoService` until every release gate below passes.

Product sequencing is fixed by **D06**: finish the mobile release first, then
desktop, then evaluate embedding. See [Roadmap after release](#roadmap-after-release).

## Approved decisions

- **D01:** Use `drift` 2.34.3 and `sqlite3` 3.5.0 with the `sqlite3mc` hook and
  explicit ChaCha20. Keep a random 256-bit hex key in device-bound
  `flutter_secure_storage`; fail closed on cipher or key-check failure.
- **D02:** Keep encrypted backup and recovery in the first production release.
- **D03:** Keep native APNs/FCM and calls in the current release scope.
- **D04:** Minimize admin audit events; omit block/member target IDs unless
  operationally required.
- **D05:** Prepare protocol/mobile review evidence now and keep production
  fail-closed until an independent external review is complete.
- **D06:** Ship mobile first. Android and iOS are the whole of release one.
  Windows and macOS come after that release, as additional targets in this
  repository reusing the reviewed Rust crypto core — **not** as a fork.
  Embedding Veritra chat in other products is deferred behind a product
  trigger and an explicit answer on whether embedded conversations stay
  end-to-end encrypted. Recorded 2026-08-07; rationale and triggers are in
  [Roadmap after release](#roadmap-after-release).

## Remaining work

Ordered by what can actually move: I28 is local and unblocked, the rest are
waiting on people, hardware, or upstream.

### I28 - Rebuild the app's visual design (active, priority)

Direction decided **2026-08-07: K2 · Bone**, after eleven variants. The owner
rejected A (reads as Viber: its `#6366F1` indigo sits about ten degrees of hue
from Viber's `#7360F2`) and C (overdone), while keeping C's plum ground.

**The palette, the per-screen spec, the deviations taken, the test contracts and
the accessibility notes are all in [`design.md`](design.md).** This card carries
only what is true of the work right now.

All eight steps are written. Steps 1-2 are committed; steps 3-8 are in the
working tree, verified but not yet committed.

**Committed (steps 1-2):** `mobile/lib/ui/tokens.dart` (new) and
`mobile/lib/ui/theme.dart` - the Bone palette for both brightnesses, radii,
spacing, motion, the type ramp, and a `VeritraStateColors` extension.
`ColorScheme.fromSeed` is gone, replaced by explicit light and dark
constructors. `veritraLightTheme()`/`veritraDarkTheme()` keep their signatures,
so `mobile/lib/main.dart` is unchanged.

**In the working tree (steps 3-8):** the shared vocabulary - `avatar.dart`,
`motion.dart`, `status_pill.dart`, `section_header.dart`, `tile_group.dart`,
`large_title_bar.dart`, `veritra_mark.dart` - plus `chat_visuals_test.dart`.
Screens touched: chat list, conversation, connect, settings, profile, device
link, invites, blocked accounts, communities, search, conversation details, the
empty state, the connection banner, and the shell's nav. Plus
`server/websetup/index.html` on Bone tokens carrying the wordmark, and the app
icon across every Android and iOS size.

No new dependency and no bundled font.

**Verification status - verified 2026-08-08** against the pinned Docker
toolchains, on the working tree described above. Every step had been written on
machines with no Flutter, Dart, Go, Rust or Docker toolchain, so this was the
first real run.

| Check | Result |
|---|---|
| `flutter analyze` | Pass - no issues found |
| `dart format --set-exit-if-changed .` | Pass, after reformatting 4 files |
| `flutter test` | Pass - 79 tests, 2 environment skips |
| `gofmt -l .` and `go vet ./...` | Pass - clean |
| `go test ./...` | Pass - every package, including `websetup` |

The first run failed, and found two defects that inspection had not:

1. **`TileGroup` wrapped `ListTile` in a `Container` carrying a background
   colour.** `ListTile` paints its background and ink splashes onto the nearest
   `Material` ancestor, so a decorated box between them hides both, and Flutter
   asserts on exactly that. This was a real defect, not a test artifact - it
   would have fired in any debug run of the settings, profile, invite,
   blocked-accounts and conversation-details screens. Fixed by making the group
   a `Material` that carries the colour, border and radius itself; the reason is
   recorded in the widget so it is not undone.
2. **`profile_screen_test.dart` could no longer find `Encryption identity
   pending`.** The taller Bone profile screen pushes that group below the 800px
   test viewport and a `ListView` does not build what it has not laid out. Fixed
   by scrolling to it in the test rather than relaxing the assertion: that
   notice being genuinely on screen is a crypto-honesty guarantee, and it
   survives scrolling.

Not covered by this run: golden tests (none exist), Android and iOS builds, the
Compose smoke, and every manual and accessibility check in I24. Rendering was
never executed - `flutter test` does not prove the screens *look* right, only
that they build, analyze, and keep their contracts.

Crypto-gated screens stay unavailable regardless of the direction chosen. The
redesign touched no crypto, storage, sync, or gate: the redacted bars read
`ciphertext.length`, which the client already holds, and decrypt nothing.

### I27 - Close upstream HPKE/libcrux advisories (upstream/review blocked)

`cargo-audit` 0.22.2 reports six advisories in the OpenMLS 0.8.1 / hpke-rs 0.6
locked graph. Three affect an optional libcrux AEAD backend that is not in the
normal build graph. Three affect SHAKE/secrets code that compiles, but the
affected XWing/ML-KEM branches are unreachable while Veritra pins the classical
X25519 MLS ciphersuite. `scripts/audit-rust.sh` records narrow, time-bounded
exceptions and fails if the optional AEAD crates become active or the fixed
ciphersuite changes. Re-review is mandatory by 2026-08-29.

No released dependency-only fix exists. OpenMLS 0.8.1 is the latest published
coordinated release and requires hpke-rs 0.6; hpke-rs 0.7 contains the libcrux
updates but is not API-compatible with that release. Do not ship a private HPKE
fork or unreleased Git dependency without independent review. Before enabling
production crypto, upgrade the coordinated OpenMLS crates when published,
refresh the lockfile/notices/SBOM, remove the exceptions, and rerun all vectors
and Android/iOS native builds.

Upstream re-checked on 2026-08-07 against the crates.io index. OpenMLS 0.8.1
(2026-02-13) is still `max_stable_version`; 0.9.0-rc.1 and 0.9.0-rc.2 were
published on 2026-08-03 and 2026-08-06. hpke-rs 0.6.1 (2026-03-20) remains the
end of the 0.6 line, with 0.7.0 published 2026-07-15. A coordinated 0.9.0 stable
therefore looks close but has not shipped. Release candidates do not satisfy
this card: adopting one is an unreleased crypto dependency and needs approval
plus independent review. Re-check before the 2026-08-29 exception deadline; if
0.9.0 stable lands first, that upgrade is the fix.

### I24 - Signed builds and real-device verification (external)

Native APNs/FCM, self-hosted TURN support, encrypted WebRTC signaling, and
unsigned Android debug/release builds are implemented. Completion requires:

1. Build signed Android and iOS release candidates from pinned native crypto.
2. Generate dependency notices, SPDX SBOM, checksums, provenance, and
   signatures through the gated release workflow.
3. On two physical devices, test setup, invite, DM/group, device link, offline
   catch-up, actions, revocation, restart, attachments, and backup restore.
4. Test FCM/APNs background wake and a TURN call across network changes.
5. Run TalkBack, VoiceOver, keyboard, large-text, background, and network-loss
   checks. Record failures; do not waive them.

Done only when signed artifacts install and the release matrix passes on every
supported Android and iOS version. Never commit signing material.

### I25 - Independent review and release gate (external)

Blocked by I24 and an independent reviewer. Completion requires:

1. Give the reviewer the immutable candidate revision, this review brief,
   vectors, build instructions, threat model, and failure tests.
2. Fix and independently retest every critical/high finding. Record lower
   findings with explicit residual-risk acceptance.
3. Rerun the clean release matrix and bind all evidence to the reviewed commit.
4. Only then replace `UnavailableCryptoService`, remove
   `PM_CRYPTO_UNAVAILABLE`, and require release readiness to pass.

Do not weaken or delete a gate to declare success.

### Crypto-gated mobile UI

The non-crypto identity and safety UI is complete: canonical named DMs, member
rosters and authorized removal/leave, block/unblock, mute, pagination,
connection state, operation-scoped failures, and corrected validation.

The following user-visible paths must remain unavailable until the reviewed
MLS service is activated and authenticated decrypted application payloads can
be rendered safely:

- reply, edit, delete, and reaction controls;
- attachment selection, upload, authenticated download, and preview;
- conversation safety-number display and confirmation;
- decrypted message rendering.

Their manual accessibility pass is part of I24. Server-authored identity must
never be presented as cryptographic verification.

## Release evidence matrix

Automated evidence below was recorded for commit
`2c5c506be274aba5239eb125428cdc510b292696`. A final candidate revision must be
recorded after the last verified change. Independent reviewer: **not assigned**.

Local verification on 2026-07-29 passed `scripts/test.ps1`,
`scripts/lint.ps1`, the live Go/Dart API contract, the native ABI lifecycle
test, the direct-license notice check, and an isolated fresh-volume Compose
health smoke. The release-readiness script failed at the intentional crypto
gate. The contract fixture was corrected to use the allowlisted
`mls10-openmls-v1` marker, and the DM block-action widget test now scrolls its
lazy list before interacting with the action. `govulncheck` initially found
three reachable Go standard-library issues; pinning Go 1.25.12 cleared them.
The CI Compose smoke job now supplies a disposable setup token so a fresh
production volume can pass startup validation without weakening the required
first-owner setup gate.

Follow-up verification on 2026-08-01 for commit `2344495` passed
`scripts/test.ps1`, `scripts/lint.ps1`, direct license notices, the 157-package
Dart license scan, and the guarded Rust advisory audit. The corrected
fresh-volume Compose smoke became healthy and returned 200 from loopback
`/healthz`; the release-readiness check still fails at the intentional crypto
gate.

Verification on 2026-08-08 covered the **uncommitted I28 working tree** on top
of `d60e45b`, using the pinned Flutter 3.44.0 and Go 1.25.12 Docker images:
`flutter analyze` clean, `dart format --set-exit-if-changed` clean after
reformatting four files, `flutter test` 79 pass with 2 environment skips,
`gofmt`/`go vet` clean, and `go test ./...` passing in every package. Two
defects were found and fixed first - see the I28 card. Rust and the Compose
smoke were not re-run, because I28 changed no Rust and no deployment file. This
evidence is not bound to a commit yet; bind it when the I28 work is committed.

| Evidence | Result | Artifact / note |
|---|---|---|
| Go tests | Pass | `go test ./...` in pinned Go 1.25 container |
| Rust tests and vectors | Pass | 17 tests with pinned Rust 1.90 |
| Flutter analyze/tests | Pass | Analyzer clean; 79 pass, 2 environment skips (2026-08-08, I28 tree) |
| Crypto-gated end-user flows | Pending | UI paths listed above remain unavailable |
| Contract/integration tests | Pass | Live server and real host native library |
| Direct license notices | Pass | Full transitive scan remains required |
| Dart package license files | Pass | 157 fetched packages contain `LICENSE*` or `COPYING*` |
| Go vulnerability scan | Pass | Go 1.25.12; zero reachable vulnerabilities |
| Rust vulnerability scan | Conditional | Guarded temporary exceptions for I27; production remains blocked |
| Android debug build | Pass | Unsigned `app-debug.apk`; not release evidence |
| Android unsigned release build | Pass | 120,668,346-byte APK; three verified native ABIs; SHA-256 `B3569C9E9D5E097822CF18FF376E2275172474871B623656A46D282E28691717` |
| Android signed release build | Pending | Requires signing approval |
| iOS reproducible release build | External | Requires macOS and signing |
| SPDX SBOM/checksums/provenance | External | Generated by the gated release workflow |
| Release-readiness gate | Expected fail, verified | `PM_CRYPTO_UNAVAILABLE` remains wired |
| Fresh-volume Compose smoke | Pass | Container became healthy; loopback `/healthz` returned 200; disposable volume removed |

| Real-device flow | Android | iOS |
|---|---|---|
| Setup, invite, DM/group | Pending hardware | Pending hardware |
| Device link and SAS | Pending hardware | Pending hardware |
| Offline catch-up and restart | Pending hardware | Pending hardware |
| Attachment and backup restore | Pending hardware | Pending hardware |
| Revocation reconnect ordering | Pending hardware | Pending hardware |
| FCM/APNs background wake | Pending credentials/hardware | Pending credentials/hardware |
| TURN call under network changes | Pending TURN/hardware | Pending TURN/hardware |
| TalkBack/VoiceOver/large text | Pending hardware | Pending hardware |

Record each independent finding here with its ID, severity, affected revision
and file, remediation revision, reviewer retest, and residual-risk decision.

## Independent security review brief

### Frozen design surface

- MLS 1.0 through OpenMLS 0.8.1 using
  `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`.
- Application marker `mls10-openmls-v1`; the server rejects other markers.
- Native ABI v4 in `crypto/rust/include/veritra_crypto.h`.
- Credentials bind length-prefixed account/device identity and the MLS
  signature key. Key packages are checked against the expected account/device.
- Local state uses SQLite3MC ChaCha20 with a random 256-bit key in platform
  secure storage. MLS state, rollback counter, affected ciphertext rows,
  dedupe marker, and sync cursor commit atomically.
- `VAP1` application payloads use versioned JSON padded to 256-byte classes.
  Authenticated context duplicates and verifies conversation, sender device,
  action ID, type, and version after decryption.
- Attachments and backups use independently authenticated AES-256-GCM chunks
  with unique keys/nonces. Attachment keys and content metadata travel only in
  MLS payloads. Recovery uses user-held 256-bit capability and encryption keys;
  older capabilities are invalidated.
- Revocation is pending, commit-submitted, then complete only after every
  snapshotted active device confirms processing the MLS removal.
- Device-link and peer-verification transcripts are domain-separated and
  length-prefixed. Safety hashes sort MLS credential/signature-key records and
  bind group ID and epoch.
- Push carries only `new_encrypted_event_available`; no sender or content.
- Call SDP/ICE is an authenticated MLS application payload. Media uses WebRTC
  DTLS-SRTP and operator-controlled TURN. Call lifecycle timing is visible.

### Required review surface

- `crypto/rust/src/mls.rs`, `mls/state.rs`, `attachment.rs`, `ffi.rs`, `lib.rs`
- `mobile/lib/crypto/`, `mobile/lib/storage/`, `mobile/lib/calls/`
- server MLS, message, attachment, backup, revocation, push, and call paths
- migrations 0021-0023, including rollback and upgrade behavior
- Android/iOS native push and native crypto packaging
- `THIRD_PARTY_NOTICES.md`, lockfiles, CI, and release scripts

### Mandatory failure cases

Test credential substitution, wrong conversation/group, unknown payload
version, padding/framing corruption, replay, duplicate/out-of-order delivery,
offline epoch gaps, wrong local database key, state rollback, interrupted
atomic commit, attachment reorder/truncation/wrong key, backup rollback/wrong
key/process death, revoked-device reconnect, malicious push payloads, plaintext
call metadata, and ABI ownership/panic failures.

The server is untrusted for confidentiality. It necessarily observes account,
device, membership, conversation, timing, ciphertext sizes, call lifecycle,
push-provider token, and attachment/backup size metadata. Anonymous routing,
federation, post-quantum protection, and hidden metadata are not claimed.

### Reviewer reproduction

```sh
./scripts/lint.sh
./scripts/test.sh
./scripts/license-check.sh
./scripts/build-mobile-crypto.sh android
cd mobile && flutter analyze && flutter test && flutter build apk --release
```

On macOS, also run `./scripts/build-mobile-crypto.sh ios`, an unsigned release
build, and the approved signing workflow. The release workflow generates SBOM,
checksums, and GitHub provenance only after every gate passes.

## Completed implementation ledger

| ID | Completed work |
|---|---|
| I01 | Established a clean baseline, fixed the fail-closed setup notice and scanner callback, and removed a deprecated secure-storage option. |
| I02 | Made key-package claims transactional, membership-scoped, requester-device excluding, and single-use. |
| I03 | Made durable mutations and matching sync events atomic; realtime publication requires a committed event ID. |
| I04 | Enforced unique two-account DMs and safe scoped roster, leave, removal, rank, and last-owner rules. |
| I05 | Added scoped message repair by ID so old edits/deletes converge outside the newest page. |
| I06 | Unified spoof-resistant HTTP/WebSocket/setup identity, enrollment, and privacy-safe login backoff. |
| I07 | Made encrypted blob writes durable, validated size/digest, added authorized range downloads, and persisted deletion retries. |
| I08 | Selected exact Drift/SQLite3MC versions and the device-bound random-key design approved in D01. |
| I09 | Added the encrypted transactional local database and moved growing state out of secure storage. |
| I10 | Added pinned reproducible Android JNI/iOS XCFramework packaging, source/license metadata, and CI symbol checks. |
| I11 | Bound ABI v2/v4 safely with typed errors, bounded secrets, finalization, close idempotence, and Dart-to-Rust lifecycle coverage. |
| I12 | Made MLS state, rollback counter, affected rows, dedupe marker, and cursor atomic with failure-injection coverage. |
| I13 | Implemented conversation MLS create/join/update/application flow and offline convergence behind the release gate. |
| I14 | Defined authenticated, bounded, padded payloads for text, reply, edit, delete, reaction, attachments, and call signaling. |
| I15 | Derived device-link SAS locally from a credential-bound transcript and removed trust in server-authored comparison values. |
| I16 | Implemented snapshot-based revoked-device removal and honest-device convergence. |
| I17 | Added streaming authenticated attachment crypto and ciphertext-only transport/storage primitives; end-user UI remains crypto-gated. |
| I18 | Added capability-based encrypted backup/recovery with rollback protection and no key escrow. |
| I19 | Added durable outbox classification/retry, typed incremental sync repair, pagination, restart recovery, and operation-scoped UI state. |
| I20 | Completed non-crypto identity/safety UI; crypto-dependent actions are listed under remaining work. |
| I21 | Added the single-writer lock, one-time setup-secret lifecycle, readiness drain, clean-host restore drill, deployment examples, and pinned toolchains. |
| I22 | Added live-server contracts for every Flutter API route, typed model/error/pagination coverage, and CI integration. |
| I23 | Hardened WebSocket handshakes and frames with adversarial, fuzz, lifecycle, slow-client, trusted-proxy, and race coverage. |
| I24 | Implemented native push, self-hosted TURN configuration, encrypted WebRTC signaling, and an Android debug build; external release checks remain. |
| I26 | Added out-of-band group safety transcripts/numbers with local persistence and changed-state detection. |

Completed non-crypto product UI also includes named DMs, canonical DM reuse,
history pagination with preserved position, role-gated roster actions, blocked
accounts, per-conversation mute, connection/sync error separation, scoped busy
state, composer clearing on durable enqueue, accurate search/navigation,
community channel navigation, password validation, honest push status, and a
wide master-detail layout.

## Roadmap after release

Decided 2026-08-07 as **D06**. One product, one repository, three phases. Each
phase starts only when the phase before it has shipped.

### Phase 1 - Mobile (current)

Android and iOS are the entire first release. Nothing below may pull work,
review attention, or dependencies forward into it.

### Phase 2 - Windows and macOS

Trigger: the mobile release has shipped and the native crypto core plus its
packaging are stable and independently reviewed.

Desktop is an **additional Flutter target in this repository**, not a fork.
Forking would produce two divergent copies of the same MLS protocol and would
owe a separate independent security review for each — the worst available
outcome for a product whose only real asset is one reviewed crypto core. The
Flutter client in `mobile/lib/` and the Rust core in `crypto/rust/` are reused
as they are.

What is genuinely new, and what the phase must design rather than inherit:
desktop key storage (there is no `flutter_secure_storage` equivalent guarantee
on Windows), update and signing channels, sandboxing, and multi-instance
behaviour against the single-writer data-dir lock. A self-hosted internal
network deployment is the same server with a desktop client attached; it needs
no server change.

This supersedes the archived R09 card in
`archive/2026-07-26/legacy-implementation/09-deferred-roadmap.md`, which set the
same trigger.

### Phase 3 - Embedded chat (deferred, needs a decision first)

Trigger: a real product asking for it, plus an explicit owner answer to one
question — **do embedded conversations stay end-to-end encrypted?**

- **Yes** - then the deliverable is a client SDK: the Rust core plus bindings,
  shipped from this repository. The embedding application performs the MLS
  operations itself. There is no drop-in widget, because there is no key on the
  server to give one.
- **No** - then it is a different product with a different server. Server-side
  plaintext contradicts the non-negotiable boundary in `AGENTS.md` and must not
  be added to this codebase to serve an embedding use case.

Until that question is answered, no embedding work starts. Note that the
current API is account-and-device shaped: there are no bot tokens, service
accounts, or machine credentials, and adding them is part of this phase, not a
prerequisite bolted on early.

## Later, not release-blocking

- Measure query plans, load, soak behavior, and push fan-out before tuning.
- Profiles/avatars, local content search, multi-account, and passkeys.
- Invite URI/QR polish, drafts, richer empty states, link previews, voice notes,
  and client-side import.
- Moderation reports and post-quantum readiness need a product trigger.
- Dead-code/wrapper cleanup waits until the release blockers are resolved.
- Out of scope: federation, PostgreSQL, S3, and NATS.

## Working rule

Preserve ciphertext-only server storage, generic push data, privacy-safe logs,
interface boundaries, and domain logic outside HTTP handlers. Run narrower
checks first, then `scripts/test` and `scripts/lint`. External release,
destructive, signing, dependency, and credential changes require approval.
