# Veritra implementation record

This is the single authoritative record for active implementation work,
completed work, release evidence, and the independent-review handoff.
Historical audits, plans, and superseded execution files are preserved in Git
history through `bfb3922` and intentionally absent from the working tree.
Their reconciled decisions live in `audit-consensus.md`.

## Current status

**NO-GO:** production crypto remains fail-closed in release builds.

**Direction since 2026-09-24 (D10–D27): local demos first.** Working local demos
on Android (emulator), iOS (simulator), Windows and Linux come before any
release work. Demo builds run the real OpenMLS path through a separate entry
point (`mobile/lib/main_demo.dart`, D11); `mobile/lib/main.dart` and the release
gate are unchanged. Independent review, signing and real-device evidence (G24,
G25) wait until all three roadmap phases are done (D20). Work order:

0. Green CI and a clean PR queue — **done 2026-09-24:** OpenMLS 0.9.0
   (closes I27/G27), Rust 1.91, Go 1.26.8, Dart dependency bumps, coverage
   floors.
1. Demo foundation — **done 2026-09-24:** demo entry point, loopback-only
   HTTP for demo builds, decrypted-message persistence (schema v7), message
   actions, MLS sender binding (ABI v5), live multi-client test
   (`scripts/test-demo-e2e.sh`), one-command local server (`scripts/demo.sh`).
   Attachments and safety-number UI are still open.
2. Mobile demo (Android emulator, iOS simulator) — **needs a machine with
   emulators;** CI builds both apps.
3. Desktop demo (Windows, Linux) — **built 2026-09-24:** Linux bundle run
   locally against the demo server; Windows built in CI only. Profiles
   (`--profile`) allow two accounts on one computer.
4. Offline use — **done 2026-09-24:** chats render from decrypted local
   history, the app opens with the server down, sends queue and deliver on
   reconnect, and the sync socket catches up after every reconnect. The live
   test stops and restarts the server. Attachment caching waits for
   attachments.
5. Remaining release-blocking cards (I33, I34, I51, I39, I45, I41).
6. Phase 2 completion (macOS, packaging, desktop key storage).
7. Phase 3 outline (client SDK).

The history below records earlier status and is kept for provenance.

Audit reconciliation and Claude's second-round review have consensus with no
open objections. T29 is implemented by Codex on 2026-08-14; its required
toolchain checks are pending because this workspace has no Go/Docker runtime.
T40A is implemented by Codex on 2026-08-14; its Cargo checks are pending. T40B
is implemented by Codex on 2026-08-14; its Go/Docker checks are pending. T40C
is implemented by Codex on 2026-08-14; its release gate intentionally blocks
without approval evidence and its Go/Docker checks are pending. T40D is
implemented by Codex on 2026-08-14; its full verification checks are pending.
T30A
is implemented by Codex on 2026-08-14; its Flutter checks are pending
because this workspace has no Flutter runtime. T31 is implemented by Codex on
2026-08-14; its Flutter checks are pending because this workspace has no
Flutter runtime. T30B is implemented by Codex on 2026-08-14; its Flutter and
Go checks are pending because this workspace has no Flutter or Go runtime.
T32 is implemented by Codex on 2026-08-14; its Flutter checks are pending
because this workspace has no Flutter runtime.
T35 is implemented by Codex on 2026-08-14; its Go checks are pending because
this workspace has no Go runtime.
T36A/T36B are implemented by Codex on 2026-08-14; their Go checks are pending
because this workspace has no Go runtime. T37A/T37B and the safe T37C
migration/idle plumbing are implemented by Codex on 2026-08-14; T37C session
rotation and cost promotion remain policy/toolchain deferred. I38 is implemented
by Codex on 2026-08-14; its Go/Flutter checks are pending. I39, I41, T42B/I43
and dependency-blocked I45 contain the remaining local release work.
T42A is implemented by Codex on 2026-08-14; its server checks are pending
because this workspace has no Go runtime. T42B design-stage work is claimed by
Codex on 2026-08-14; its proposed platform design remains pending explicit
approval before native permissions or provider changes.

T43A/T43B/T43C are implemented by Codex on 2026-08-14; their Flutter checks
and T43C's golden/device evidence are pending because this workspace has no
Flutter runtime or signed-device environment.

The branding assets were the last place where the repository still showed the
palette I28 dropped: only the app icon had been redrawn, so the root README,
the favicon and the primary mark still shipped Indigo→Sky. Those were redrawn
on Bone on 2026-08-18 and every raster re-rendered from its SVG with macOS
QuickLook, which also retires the "no rasteriser was available" caveat in
[`design.md`](design.md). Visual verification was by rendered contact sheet,
not by device; golden tests remain the known gap and are now unblocked, since
the pinned Flutter image can generate them in a container.
I24, I25 and I27 still need signing credentials, supported physical Android
and iOS devices, macOS for the iOS build, an operator-controlled TURN
deployment, push-provider credentials, a coordinated upstream OpenMLS/HPKE
security update and an independent security reviewer. Do not remove
`PM_CRYPTO_UNAVAILABLE` or replace `UnavailableCryptoService` until every
release gate below passes.

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
  [Roadmap after release](#roadmap-after-release). **Ordering superseded by
  D10 on 2026-09-24**; the no-fork rule and the embedding question stand.
- **D07:** The Codex and Opus audits are source evidence, not competing
  backlogs. [`audit-consensus.md`](audit-consensus.md) is their authoritative
  disposition and source-to-card trace. This board alone owns implementation
  status. Recorded 2026-08-13.
- **D08:** [`implementation/REMAINING_WORK.md`](../implementation/REMAINING_WORK.md)
  contains claimable LLM execution contracts derived from the consensus. It
  may split a card into non-overlapping tasks but cannot change scope,
  severity, dependencies or status. This board and the consensus win on any
  conflict. Recorded 2026-08-13.
- **D09:** Keep only current authoritative documents and live execution
  contracts in the working tree. Completed contracts, raw audits, obsolete
  testing reports, historical plans, and superseded brand assets remain
  recoverable from Git history at `bfb3922` but are not executor context.
  Recorded 2026-08-24.

Recorded 2026-09-24 by the owner's direction ("decide what you can; skip
independent reviews until all three phases are done"):

- **D10:** Local demos first on Android, iOS, Windows and Linux, before any
  release work. Desktop starts now instead of after the mobile release.
  Embedding stays phase 3. No build is released before G24/G25 pass.
- **D11:** Demo builds run the real `NativeCryptoService` through
  `mobile/lib/main_demo.dart`, guarded by `--dart-define=VERITRA_DEMO=true`
  and labelled "Demo · unreviewed crypto", with their own data namespace.
  `main.dart` and `crypto/rust/src/lib.rs` stay unchanged, so
  `scripts/release-readiness.sh` still blocks releases. The server never sees
  plaintext.
- **D12:** Demo builds accept `http://` only for loopback (`localhost`,
  `127.0.0.0/8`, `::1`); the Android emulator reaches the host through
  `adb reverse`. Every other host needs HTTPS. Release builds keep rejecting
  cleartext. This narrows the "no development bypass" note in
  `audit-consensus.md` (I43) to release builds.
- **D13:** Close I27/G27 by upgrading to OpenMLS 0.9.0 (hpke-rs 0.7), which
  needs Rust 1.91. Done 2026-09-24; see I27.
- **D14:** The canonical Go toolchain is the latest 1.26 patch (1.26.8).
- **D15:** Stay on Flutter 3.44.0 and hold `sqlite3` at 3.5.x until the Flutter
  pin moves in Stage 6 (`sqlite3` 3.6.0 needs a newer `meta` than the SDK
  ships). Amends D01's exact versions: `drift` 2.34.4, `sqlite3` 3.5.2.
- **D16:** Demos use in-app, foreground calls only. T42B (CallKit, PushKit,
  Android Telecom) waits until after the demos.
- **D17:** T37C stays as it is (bcrypt cost 10, no token rotation) until
  release prep.
- **D18:** CI coverage floors are the measured baseline rounded down (Go 50%,
  Flutter 43%) and only move up. See `testing/evidence/coverage-baseline.md`.
- **D19:** Phase 3 answer: embedded conversations stay end-to-end encrypted,
  so phase 3 ships a client SDK, never a server-plaintext widget.
- **D20:** Deferred until all three phases are done: G24, G25, QA02, new
  release-evidence work, I47/I49 evidence, T42B. Existing gates and their
  tests stay green.
- **D21:** The Flutter app stays in `mobile/` and becomes the app for every
  platform.
- **D22:** Reply, edit, delete and reaction are ordinary MLS application
  messages that reference their target by the authenticated
  `<sender_device_id>:<action_id>`. Edit and delete are honoured only from the
  original sender's account. `payload_type` leaves server-visible metadata, and
  the server's edit/delete/reaction routes go unused.
- **D23:** Decrypted text is persisted at decrypt time in the same transaction
  as the MLS state, in dedicated tables. It is removed only by identity change,
  reset, delete or expiry, never by a cache refresh.
- **D24:** Demo topology until I51 lands: one device per account and fixed
  group membership; demo builds hide "Add member" and "Link device".
- **D25:** Decryption binds the MLS sender credential to the envelope's sender
  account and device (native ABI v5). A mismatch commits an "unverifiable"
  tombstone instead of stalling sync.
- **D26:** Demo desktop key storage uses Windows DPAPI and the Linux Secret
  Service; reviewed in Stage 6. Never generate a new database key while the
  database file exists.
- **D27:** Encrypted backups include decrypted history (implemented in I45).
- The crypto surface (ABI v5, payload semantics, local schema v7) freezes after
  Stage 1, with a change log kept for the eventual G25 reviewer.

## Remaining work

Ordered by production impact and dependency. Detailed scope, disputes and
acceptance checks are in [`audit-consensus.md`](audit-consensus.md); claimable
task boundaries and orchestration rules are in
[`implementation/REMAINING_WORK.md`](../implementation/REMAINING_WORK.md).

### Audit-derived implementation queue

| ID | Status | Work | Depends on |
|---|---|---|---|
| I29 | Implemented; checks pending (Codex, 2026-08-14) | Recovery capability secrecy and lifecycle | — |
| I30 | Implemented (T30A/T30B); checks pending (Codex, 2026-08-14) | One MLS-aware sync owner | — |
| I31 | Implemented (T31); checks pending (Codex, 2026-08-14) | Lossless message outbox | — |
| I32 | Implemented (T32); checks pending (Codex, 2026-08-14) | Account-scoped session lifecycle | — |
| I33 | Implemented and checked (Stage 5, 2026-09-24) | Poison-event and stale-device recovery | I30 |
| I34 | Blocked by I31 | Reliable MLS control outbox | I31 pattern |
| I35 | Implemented (T35); checks pending (Codex, 2026-08-14) | Retention and attachment-prune convergence | — |
| I36 | T36A/T36B implemented; checks pending (Codex, 2026-08-14) | Committed-message fanout and bounded push work | — |
| I37 | T37A/T37B implemented; T37C safe migration/idle plumbing implemented; rotation and cost promotion deferred; checks pending (Codex, 2026-08-14) | Setup and authentication hardening | — |
| I38 | Implemented (T38); checks pending (Codex, 2026-08-14) | Safe account export | — |
| I39 | Blocked by I32 | Fail-closed encrypted database key recovery | I32 |
| I40 | T40A/T40B/T40C/T40D implemented; checks pending (Codex, 2026-08-14); due 2026-08-29 | Release evidence and toolchain integrity | — |
| I41 | Blocked by I36, conditional D03 | Push registration and platform readiness | I36 |
| I42 | T42A implemented; T42B design claimed/proposed, approval pending; checks pending (Codex, 2026-08-14), conditional D03 | Authorized calls and native lifecycle | — |
| I43 | T43A/T43B/T43C implemented; checks/evidence pending (Codex, 2026-08-14) | First-run and accessibility baseline | — |
| I44 | Prepared, split before claim | Mobile and API quality | release blockers |
| I45 | Blocked by I29/I39, required by D02 | Backup, restore and migration safety | I29, I39 |
| I46 | Prepared | Supported deployment hardening | — |
| I47 | Prepared, conditional | Operational visibility and capacity evidence | I35, I36 |
| I48 | Prepared | Transport, realtime and logging hardening | I32 |
| I49 | Measure, then split | Performance and architecture work | correctness cards |
| I50 | Deferred | Product and ecosystem backlog | D06 / mobile release |
| I51 | New 2026-09-24, prepared | MLS membership changes after creation, linked devices, per-device key-package claims, join cursor, epoch-ordered commits | I30, I34 |

No audit-derived implementation is complete merely because it appears in this
table. Claim one eligible task under the Ready card, confirm its source paths
still match current code, run its named checks, then update this board and the
consensus register.

### I27 - Close upstream HPKE/libcrux advisories (closed 2026-09-24, pending CI)

OpenMLS 0.9.0 stable shipped on 2026-08-25 with hpke-rs 0.7, the upgrade this
card named as the fix. The exceptions expired on 2026-08-29 and turned the
`vulnerabilities` job and the nightly `Rust policy expiry` workflow red until
the upgrade landed (D13).

Done on 2026-09-24:

- `openmls` 0.9.0, `openmls_basic_credential`/`openmls_rust_crypto`/
  `openmls_traits` 0.6.0 and `tls_codec` 0.5.0, exactly pinned. OpenMLS 0.9
  needs Rust 1.91, now the pinned toolchain. `mls.rs` compiled unchanged; all
  Rust tests pass (20, including a new check that sealed state from the 0.8.1
  format fails closed; `mls/state.rs` envelope format version is now 2).
- `cargo audit` 0.22.2 over the 206-crate lockfile reports no vulnerabilities
  with **no** ignores (one allowed "unmaintained" warning for
  `proc-macro-error2`, a build-time macro crate). `crypto/rust/audit-policy.json`
  now approves no exceptions, and `scripts/check-rust-audit-policy.py` accepts
  an empty list; the deadline only bounds exceptions that exist.
- `scripts/audit-rust.sh` still fails if an optional libcrux AEAD backend
  (`libcrux-aes`, the renamed `libcrux-aesgcm`, or `libcrux-chacha20poly1305`)
  enters the normal build graph, or if the classical ciphersuite changes. The
  post-quantum crates now in the graph (`ml-kem`, `ml-dsa`, `x-wing`) stay
  unreachable with that suite.
- Notices and `docs/crypto.md` refreshed (205 third-party crates, all
  licensed compatibly).

Still required before production crypto, as part of G25: rerun the
Android/iOS native builds (CI) and include the upgrade in the independent
review scope.

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

In release builds (`mobile/lib/main.dart`), the following user-visible paths
must remain unavailable until the reviewed MLS service is activated and authenticated decrypted application payloads can
be rendered safely:

- reply, edit, delete, and reaction controls;
- attachment selection, upload, authenticated download, and preview;
- conversation safety-number display and confirmation;
- decrypted message rendering.

Demo builds (`main_demo.dart`, D11) may show them, always with the demo label.
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

Verification on 2026-08-08 covered the final I28 tree on top of `d60e45b`,
using the pinned Flutter 3.44.0 and Go 1.25.12 Docker images:
`flutter analyze` clean, `dart format --set-exit-if-changed` clean after
reformatting four files, `flutter test` 79 pass with 2 environment skips,
`gofmt`/`go vet` clean, and `go test ./...` passing in every package. Two
defects were found and fixed first. That exact relevant source tree was
committed as `6083e3f`; no mobile, web-setup or branding file changed between
that commit and `194bd0c`. Rust and the Compose smoke were not re-run because
I28 changed no Rust or deployment file. Golden, manual and real-device visual
evidence remains in I24/I43.

| Evidence | Result | Toolchain / artifact / note |
|---|---|---|
| Go tests | Pass | Go 1.25.12; `go test ./...` in pinned container |
| Rust tests and vectors | Pass | Rust 1.91; 20 tests; OpenMLS 0.9.0 (2026-09-24) |
| Flutter analyze/tests | Pass | Flutter 3.44.0; analyzer clean; 79 pass, 2 environment skips (`6083e3f`) |
| Crypto-gated end-user flows | Pending | No activated production crypto toolchain; UI paths listed above remain unavailable |
| Contract/integration tests | Pass | Go 1.25.12 and real host native library |
| Direct license notices | Pass | Host tooling; full transitive scan remains required |
| Dart package license files | Pass | Flutter 3.44.0; 157 fetched packages contain `LICENSE*` or `COPYING*` |
| Go vulnerability scan | Pass | Go 1.25.12; zero reachable vulnerabilities |
| Rust vulnerability scan | Pass | Rust 1.91; cargo-audit 0.22.2, no exceptions (2026-09-24, local; CI pending) |
| Android debug build | Pass | Flutter 3.44.0; unsigned `app-debug.apk`; not release evidence |
| Android unsigned release build | Pass | Flutter 3.44.0; 120,668,346-byte APK; three verified native ABIs; SHA-256 `B3569C9E9D5E097822CF18FF376E2275172474871B623656A46D282E28691717` |
| Android signed release build | Pending | Flutter release toolchain; requires signing approval |
| iOS reproducible release build | External | Flutter 3.44.0; requires macOS and signing |
| SPDX SBOM/checksums/provenance | External | Gated Go 1.25.12 release workflow; generated at publication |
| Release-readiness gate | Expected fail, verified | Host tooling; `PM_CRYPTO_UNAVAILABLE` remains wired |
| Fresh-volume Compose smoke | Pass | Go 1.25.12 container; healthy; loopback `/healthz` returned 200; disposable volume removed |

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

T43C adds automated semantic-label, 320dp/200% text-scale and compact-nav
contracts in `mobile/test/ui_accessibility_test.dart`; Flutter execution is
pending in this workspace. Golden screenshots, browser rendering, signed
device runs and TalkBack/VoiceOver checks remain G24 evidence, not claims made
by the automated tests.

Record each independent finding here with its ID, severity, affected revision
and file, remediation revision, reviewer retest, and residual-risk decision.

## Independent security review brief

### Frozen design surface

- MLS 1.0 through OpenMLS 0.9.0 using
  `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`.
- Application marker `mls10-openmls-v1`; the server rejects other markers.
- Native ABI v5 (sender binding, D25) in `crypto/rust/include/veritra_crypto.h`.
- Credentials bind length-prefixed account/device identity and the MLS
  signature key. Key packages are checked against the expected account/device.
- Local state uses SQLite3MC ChaCha20 with a random 256-bit key in platform
  secure storage. MLS state, rollback counter, affected ciphertext rows,
  decrypted history, dedupe marker, and sync cursor commit atomically.
- Decrypted history (schema v7, D22/D23) lives in `local_messages` and
  `local_message_reactions`, keyed by the authenticated
  `<sender_device_id>:<action_id>`. Edits and deletes apply only when the
  authenticated sender account matches the original. Server-visible
  `crypto_metadata` no longer names the payload type.
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
| I28 | Landed the K2 Bone visual system, all app screens, shared widgets, web setup and Android/iOS icons in `6083e3f`; automated Flutter/Go checks passed, while golden/manual/device evidence remains in I24/I43. Closed out on 2026-08-18 by redrawing the `concept-06` mark family on Bone — mark, wordmarks, favicon and every raster export — and re-rendering the Android/iOS launcher icons from the SVG. The replaced Indigo→Sky assets are available only in Git history through `bfb3922`. |

Completed non-crypto product UI also includes named DMs, canonical DM reuse,
history pagination with preserved position, role-gated roster actions, blocked
accounts, per-conversation mute, connection/sync error separation, scoped busy
state, composer clearing on durable enqueue, accurate search/navigation,
community channel navigation, password validation, honest push status, and a
wide master-detail layout.

## Roadmap after release

Decided 2026-08-07 as **D06**. One product, one repository, three phases.
Since D10 (2026-09-24), working local demos of phases 1 and 2 come first; the
release triggers below apply to shipping, not to building demos.

### Phase 1 - Mobile (current)

Android and iOS are the entire first release. Nothing below may pull work,
review attention, or dependencies forward into it.

### Phase 2 - Desktop (Windows, Linux, then macOS)

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

This preserves the same trigger as the historical R09 contract, available in
Git history at `bfb3922` if provenance is needed.

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
