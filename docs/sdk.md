# Client SDK (Phase 3 outline)

Status: **outline, 2026-09-25.** Nothing here is built. Decision D19 fixed the
direction: embedded conversations stay end-to-end encrypted, so phase 3 ships a
client SDK from this repository, never a server-plaintext widget. Everything
below marked **Proposal** is a design choice for the team to confirm; every
other statement describes code as it is today.

Prerequisites, from the board:

- Phase 3 work starts after phases 1 and 2 reach working demos (D10). G24 and
  G25 wait until all three phases are done (D20).
- The SDK never changes the release gate: `mobile/lib/main.dart` keeps
  `UnavailableCryptoService()`, `crypto/rust/src/lib.rs` keeps
  `pm_crypto_available()` returning `PM_CRYPTO_UNAVAILABLE`, and
  `scripts/release-readiness.sh` keeps failing on both.
- New dependencies need license review and `THIRD_PARTY_NOTICES.md` updates.

## 1. Goal and non-goals

Goal: let another application be a Veritra endpoint. The embedding app's users
(or its bots) hold their own MLS devices, and the SDK performs enrollment, MLS,
sync, the outbox and payload handling on the host device, talking to a
Veritra server extended only by §5.

Non-goals:

- No server-side plaintext, decryption, search or rendering of any kind.
- No drop-in widget or iframe served by the Veritra server. There is no server
  key to give one.
- No fork of the crypto core. `crypto/rust` stays the single MLS
  implementation; the SDK links it.
- No new wire protocol. The SDK speaks `mls10-openmls-v1`, the `VAP1` payload
  format and the existing HTTP/WebSocket API, so SDK clients and the Flutter
  app share conversations.
- Not in the first SDK release: calls (`callSignal` payloads), encrypted backup
  and recovery, device linking, communities and admin routes.

## 2. Layering

### What exists today

| Layer | Where | Notes |
|---|---|---|
| MLS core | `crypto/rust/src/mls.rs`, `mls/state.rs` | `MlsDevice`: key packages, enrollment credential, group create/join/stage/merge/process, encrypt/decrypt, safety number, `seal_state`/`restore_state` with a rollback counter. `pub mod mls` is already a Rust API. |
| Attachment chunks | `crypto/rust/src/attachment.rs` | AES-256-GCM chunk encrypt/decrypt. |
| C ABI v6 | `crypto/rust/src/ffi.rs`, `include/veritra_crypto.h` | Opaque `PmCryptoHandle` (a `Mutex<MlsDevice>`), zero-on-free `PmOwnedBuffer`, `catch_unwind` on every call. |
| Dart binding | `mobile/lib/crypto/native_crypto_bindings.dart` | Requires ABI 6 exactly; also encodes the ABI 6 membership-change byte format. |
| MLS orchestration | `mobile/lib/crypto/native_crypto_service.dart` | Serialises every operation (`_serial`), seals the whole state after each mutation (`_sealNext`), commits it with the cursor (`commitMlsTransition`), reloads on counter drift (`_requiredState`), handles own commits, Welcome, sender mismatch tombstones. |
| Payload codec | `mobile/lib/crypto/app_payload.dart` | `AppPayloadCodec`: `VAP1` magic, JSON, 256-byte padding, 64 KiB max, context check of conversation, sender device, action ID. |
| Commit bundles | `mobile/lib/crypto/mls_commit_bundle.dart` | D28 bundle (commit, Welcome, roster change, epoch). |
| Attachment files | `mobile/lib/crypto/attachment_crypto.dart` | 1 MiB chunks, 48 MiB cap, manifest; calls the native chunk functions. |
| Sync and outbox | `mobile/lib/core/app_state.dart`, `mobile/lib/sync/` | `_runOwnedCatchUp` pages `GET /api/v1/sync/events` (200 per page), applies events one by one, then revocations and `_reconcileMlsMembership` (coordinator, 3-minute fallback); `_flushOutbox`; `AccountSyncEngine` coalesces requests; `WebSocketSyncService` reconnects with backoff and emits `sync.connected`. |
| Local store | `mobile/lib/storage/local_store.dart` | `LocalStore` interface; Drift/SQLite3MC implementation; database key in `flutter_secure_storage`. |
| API client | `mobile/lib/core/api_client.dart` | Every route the app uses. |

The protocol-critical logic that must be identical on every endpoint (D22 edit
and delete authority, D25 sender binding, D28 staged commits and epoch order,
I33 stop-don't-skip sync, I34 ordered MLS outbox) lives today in Dart, and a
large part of it inside `AppState`, a `ChangeNotifier` that also owns UI state.

### Where each part goes

| Part | Decision |
|---|---|
| `crypto/rust` core and ABI v6 | Reused as is. The SDK adds no function to it. |
| MLS orchestration (`NativeCryptoService` logic) | Moves to the shared layer. |
| Sync catch-up, recovery stop, revocations, membership reconcile | Moves to the shared layer, out of `AppState`. |
| Message and MLS outboxes | Moves to the shared layer. |
| `VAP1` codec, commit-bundle codec, membership-change encoding | Moves to the shared layer. |
| Attachment file crypto and manifest | Moves to the shared layer. |
| Local store | Shared layer defines and implements it; host supplies the key (below). |
| Secure key storage, data directory, UI, notifications, push tokens | Stays per host. |

### Option A: orchestration in each binding

Each language re-implements `NativeCryptoService` and the sync loop over the C
ABI, as Dart does now.

- For: no new Rust crate; the C ABI stays the only native surface.
- Against: N copies of the most failure-prone code (the I33/I34/D28 paths), each
  needing its own review. That is the fork the board rejects for desktop,
  moved one layer up.

### Option B: one Rust orchestration crate (**Proposal: recommended**)

A new crate above the core owns the session, store, sync, outbox and codecs.
Bindings are thin, generated wrappers.

- For: one reviewed copy of the protocol logic; the core is called as a Rust
  library (`mls::MlsDevice`), not through raw pointers; the same tests run for
  every language.
- Against: the Dart logic is rewritten once in Rust, and until the Flutter app
  moves onto it there are two copies. Closing that gap is an open question (§8).

Proposed layout:

```
crypto/rust/          private_messenger_crypto  unchanged: OpenMLS core, C ABI v6
sdk/core/             veritra_sdk               rlib: session, store, sync, outbox, codecs
sdk/ffi/              veritra_sdk_ffi           cdylib/staticlib: UniFFI scaffolding only
sdk/kotlin/           generated Kotlin package, Android AAR, sample
sdk/swift/            generated Swift package, XCFramework, sample
sdk/vectors/          shared payload/bundle vectors used by Rust and Dart tests
```

**Proposal:** make the repository root a Cargo workspace holding
`crypto/rust` and both SDK crates, with one `Cargo.lock`, so the core cannot
drift between the app and the SDK. `scripts/audit-rust.sh`,
`scripts/cargo-license-metadata.py` and `crypto/rust/audit-policy.json` then
need to follow the lockfile.

## 3. Public API sketch (**Proposal**)

Shown as Rust; UniFFI maps it to Kotlin and Swift. All names are provisional.

### Host-supplied hooks

The host supplies storage *capabilities*, not storage *logic*. The atomicity
rules (MLS state, rollback counter, cursor, dedupe marker and decrypted history
in one transaction; see the board's frozen design surface) are security
properties and stay inside the SDK.

```rust
trait SecretStore: Send + Sync {        // Keychain, Keystore, DPAPI, Secret Service
    fn get(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>, HostError>;
    fn put(&self, name: &str, value: &[u8]) -> Result<(), HostError>;
    fn delete(&self, name: &str) -> Result<(), HostError>;
}
trait EventSink: Send + Sync {          // called off the host's UI thread
    fn on_event(&self, event: SdkEvent);
}
struct SdkConfig {
    server_url: Url,          // HTTPS; loopback http only in demo builds (D12)
    data_dir: PathBuf,        // SDK-owned encrypted database and temp files
    namespace: String,        // like main_demo.dart's data namespace and --profile
    secrets: Arc<dyn SecretStore>,
    events: Arc<dyn EventSink>,
}
```

**Proposal:** the SDK owns an encrypted SQLite database in `data_dir` with the
same schema meaning as the Flutter store (v8), and keeps only its 256-bit
database key in `SecretStore`. The D26 rule carries over: never generate a new
key while the database file exists.

### Lifecycle and enrollment

```rust
Sdk::open(config) -> Result<Sdk>                     // fails Unavailable unless the gate allows it (§6)
sdk.register(invite, username, password) -> Session  // reserve enrollment, create credential, POST /register
sdk.login(username, password) -> Session             // existing device only: password + device secret
sdk.resume() -> Option<Session>                      // restore sealed state, check the rollback counter
session.logout() / session.logout_all()
session.devices() / session.revoke_device(id)        // revoke needs recent auth, as today
session.close()                                      // drains the sync owner, zeroes the handle
```

Enrollment follows the existing flow: the server reserves account and device IDs
(`/api/v1/register/enrollment`), the SDK calls `create_enrollment_credential`
and signs the challenge, and the server verifies the proof. Service accounts
enrol differently (§5).

### Conversations and messages

```rust
session.conversations() -> Vec<Conversation>
session.create_conversation(kind, members) -> Conversation   // claims key packages, queues the D28 bundle
session.add_member / remove_member / leave
session.messages(conversation_id, page) -> Vec<LocalMessage> // decrypted local history only
session.send(conversation_id, Outgoing) -> ActionId          // durable enqueue; returns before delivery
enum Outgoing { Text{text}, Reply{target, text}, Edit{target, text},
                Delete{target}, Reaction{target, emoji}, Attachments{files} }
session.safety_number(conversation_id) -> SafetyNumber
```

`Outgoing` maps one-to-one onto `AppPayloadType` minus `callSignal`. Targets are
the authenticated `<sender_device_id>:<action_id>` keys (D22). The SDK enforces
D22 on receive: edits and deletes apply only from the original sender's account.

### Attachments

`Attachments{files}` encrypts each file in 1 MiB chunks with a random key and
nonce prefix, uploads ciphertext only with `{version, algorithm, chunk_size}`,
and sends the manifest inside the MLS message. `session.open_attachment(ref,
dest)` downloads, checks `ciphertext_size`, and decrypts to a host-chosen path
or stream. Keys never leave the MLS payload and the encrypted database.

### Sync and events

The SDK runs one sync owner per session, like `AccountSyncEngine`: a WebSocket
wake, `session.wake()` from a host push handler, or a timer all request the same
coalesced catch-up. Events delivered to `EventSink`:

| Event | Meaning |
|---|---|
| `MessagesChanged{conversation_id}` | Local history changed; host re-reads it. Carries no plaintext. |
| `ConversationsChanged` | Roster, membership or retention projection changed. |
| `Connection{online, error_kind}` | Connection fact, not an operation result. |
| `SyncStopped{recovery}` | I33 stop; host must offer the recovery choice. |
| `SendFailed{action_id, terminal}` | Outbox entry classified terminal. |
| `SessionEnded{reason}` | 401, revocation, or reset; device identity kept where the app keeps it. |

Plaintext is read through `messages()`, never pushed through events, so a host
that logs events cannot leak content by accident.

### Error model

One `SdkError` enum; no variant carries message text, keys, tokens or ciphertext.

| Variant | Source today |
|---|---|
| `Unavailable` | Gate closed (§6); mirrors `PM_CRYPTO_UNAVAILABLE`. |
| `InvalidArgument` | `PM_CRYPTO_INVALID_ARGUMENT`, codec `FormatException`s. |
| `Crypto` | `PM_CRYPTO_ERROR`, `PM_CRYPTO_PANIC`; opaque. |
| `Unauthorized`, `RecentAuthRequired` | HTTP 401, 403 `recent_auth_required`. |
| `RateLimited{retry_after}` | HTTP 429. |
| `Network{retryable}` | Transport failures; retried with backoff up to 60 s as in `_scheduleCatchUpRetry`. |
| `Storage`, `StateRollback` | Store unavailable; counter mismatch on restore. |
| `OutboxFull` | `OutboxFullException`. |

`PM_CRYPTO_SENDER_MISMATCH` is not an error: it becomes an `unverifiable`
history row and sync continues (D25).

### Threading and async

The core is already safe to call from one thread at a time
(`Mutex<MlsDevice>`); the Dart service adds `_serial` so a whole transition
(decrypt, seal, commit) is atomic. **Proposal:** each `Session` is an actor: one
task owns the `MlsDevice`, the store connection and the sync loop, and every
public call is a message to it. Public calls are `async` (UniFFI async maps to
Kotlin coroutines and Swift `async`). `EventSink` is called from the SDK's
thread. Which async runtime to embed is open (§8); it is a new dependency either
way.

## 4. Bindings and targets

**Proposal: Kotlin (Android and JVM) and Swift (iOS and macOS) first.**
Products that embed a messenger are overwhelmingly native mobile apps, and both
platforms have the hardware-backed key stores the security model needs. The
same crate also serves server-side JVM bots. A plain C header for other hosts
comes later; TypeScript/WASM is out of scope because a browser has no
equivalent of device-bound secure storage.

**Proposal: UniFFI for the SDK, not a second hand-written C ABI.** The SDK API is
large, async and callback-driven; UniFFI generates the Kotlin and Swift glue,
object lifetimes and error mapping from one definition. The hand-written C ABI
stays where it is: small, frozen and already reviewed for the Flutter app.
UniFFI (MPL-2.0) and its generated code need license review and join the G25
review surface.

Versioning and compatibility:

| Surface | Rule |
|---|---|
| C ABI (`PM_CRYPTO_ABI_VERSION` 6) | Untouched by SDK work. The SDK links the core as an rlib, so it never calls it through the C ABI. Any later ABI change follows the existing rule: bump the version, log it in `crypto.md`, and the Dart binding keeps requiring an exact match. |
| SDK API | Semantic versioning, starting at 0.x while unreviewed. |
| Generated bindings | Built from the same commit as the native library; a binding refuses to load a library from a different build (UniFFI checksum). |
| Wire and payload | `mls10-openmls-v1`, `VAP1` version 1, sealed-state envelope version 2. Changing any of them is a crypto change for the `crypto.md` change log, not an SDK release detail. |
| Local database | Same migration discipline as the Flutter store; never auto-delete on a failed key check. |

Packaging reuses the pinned native build path of `scripts/build-mobile-crypto.sh`
and `scripts/build-desktop-crypto.sh` (Android JNI libraries, iOS XCFramework),
extended to the SDK crates.

## 5. Server-side additions

Today every authenticated route goes through `withAuth` in
`server/internal/httpapi/api.go`, which resolves a bearer token to a
`domain.Principal` (account, device, role, recent-auth time). Tokens come from
`POST /api/v1/auth/login` with username, password and device secret, or from
registration. Rate limits are per client IP hash (`newRateLimiter(clientIdentities,
240, 10, 5)` in `server/internal/app/app.go`). There is no service account,
bot token or machine credential. **All of the following is a proposal.**

### Service accounts

- A service account is an ordinary account with `kind = service`, created by an
  admin with recent auth, and owned by a human account.
- Its devices are ordinary MLS devices: same credential binding, same key
  packages, same roster and join cursor, same revocation. It gets no special
  crypto path, so it can read exactly the conversations it is a member of,
  like any other member.
- Clients show service members with a distinct label. That label is
  server-authored and must never be presented as cryptographic verification.
- No password. A service device authenticates by signing a server challenge
  with its MLS credential key (the key `sign_enrollment_challenge` already uses)
  and receives a short-lived token. Nothing long-lived and bearer-shaped is
  stored on the bot host except the sealed MLS state and its key.

### Scoped tokens

| Scope | Allows |
|---|---|
| `sync` | `GET /api/v1/sync/events`, `/sync/ws`, MLS message reads. |
| `messages:send` | Envelopes, MLS messages and commit bundles. |
| `attachments` | Upload and download of ciphertext blobs. |
| `conversations:join` | Accept invites, claim key packages. |

Scopes can also be limited to a list of conversation IDs. Service tokens never
satisfy `withRecentAuth`, so they cannot create invites, revoke devices, export
or delete accounts, or use admin routes. The check belongs in the domain layer,
not only in handlers.

### Embedding apps with human users

An embedding product's backend may provision accounts for its users (for
example after its own sign-in). **Proposal:** a `provision` scope lets it reserve
an account and a one-time enrollment, but the device key is generated and the
enrollment proof signed on the user's device by the SDK. The provisioning
backend never holds a device, so it cannot read messages.

### Rate limits and audit

- Add per-principal buckets next to the per-IP ones, so many users behind one
  embedding backend's egress IP do not share a limit, and one bot cannot starve
  others.
- Audit events, minimal per D04: `service_account.created`, `.token_issued`,
  `.scope_changed`, `.revoked`, `provision.enrollment_reserved`. Metadata holds
  IDs and scope names only; never tokens, request bodies or ciphertext.

## 6. Security model

Trust, stated plainly:

| Party | Trusted with |
|---|---|
| Veritra server | Nothing confidential; unchanged from today's threat model. |
| Embedding app process | Everything its SDK session holds: plaintext, the database key, the sealed MLS state. It *is* the endpoint; the SDK cannot protect users from a malicious host app. |
| Embedding app backend | Nothing, unless it runs its own SDK device (then it is a member like any other). A `provision` token grants account creation, not reading. |
| Bot host | The plaintext of the conversations the bot has joined. Members see the bot in the roster and the safety number. |

Key storage per host:

| Host | Database key (`SecretStore`) |
|---|---|
| Android | Keystore-backed storage, device-bound, as in D01. |
| iOS, macOS | Keychain `ThisDeviceOnly`. |
| Windows, Linux desktop | DPAPI, Secret Service (D26). |
| Server bot | OS secret store or a file readable only by the service user; documented, not hidden. |

Gate. **Proposal:** the SDK has its own fail-closed gate equivalent to D11:
`Sdk::open` returns `Unavailable` unless the crate is built with an explicit
`unreviewed-demo` feature, and that build labels itself unreviewed. Release
builds of the SDK stay blocked on the same G25 evidence as the app;
`scripts/release-readiness.sh` gains a check for the SDK gate and keeps its
existing checks unchanged.

What G25 must cover in addition to the current review surface:

- `sdk/core`: session actor, store transactions, rollback counter, sync stop,
  outboxes, D22/D25/D28 enforcement, codecs, attachment handling.
- UniFFI scaffolding and generated Kotlin/Swift: lifetimes, zeroing, errors,
  panics across the boundary, callback reentrancy.
- Each `SecretStore` reference implementation and the documented host contract.
- Server: service accounts, challenge-signed tokens, scope enforcement,
  `withRecentAuth` exclusion, per-principal limits, audit contents.
- Codec parity: Dart and Rust produce and accept the same vectors.
- Added failure cases: host storage that loses writes or returns stale values,
  two SDK instances on one `data_dir`, a token used outside its scopes or
  conversations, a provisioning backend attempting to enrol a device, a bot
  removed mid-epoch.

## 7. Milestones

Each is small, ordered and has its own check. None ships.

| # | Milestone | Check |
|---|---|---|
| M0 | Workspace and gate: Cargo workspace, empty `veritra_sdk`, `Sdk::open` returns `Unavailable` without the feature. | `cargo test`; release-readiness still fails for the same reasons. |
| M1 | Codecs in Rust: `VAP1`, commit bundle, membership-change encoding; shared vectors in `sdk/vectors/`. | Rust and Dart tests both pass the same vectors. |
| M2 | Store and state: encrypted database, `SecretStore`, atomic transition with counter and cursor, restore-on-drift. | Ported failure-injection tests (interrupted commit, rollback, wrong key). |
| M3 | Session and sync: enrol, resume, catch-up with I33 stop, MLS outbox (I34), D28 reconcile, text send and receive. | A Rust test client and the Flutter demo client exchange messages against `scripts/demo.sh`, extending `scripts/test-demo-e2e.sh`. |
| M4 | All message payloads and attachments. | Edit/delete authority, sender mismatch, attachment size and context checks. |
| M5 | UniFFI bindings, Android AAR, Swift package, one sample app each. | Samples chat with the Flutter demo on emulator and simulator. |
| M6 | Server service accounts, challenge-signed scoped tokens, per-principal limits, audit. | Go tests for scope and recent-auth refusal; no token or body in logs. |
| M7 | Bot sample on the JVM or a Rust CLI, using M6. | Bot joins, replies, is shown as a service member, is revoked. |
| M8 | Decide and, if chosen, move the Flutter app onto `veritra_sdk`. | Full Flutter suite and demo e2e unchanged. |

## 8. Open questions

1. **One copy or two.** Does the Flutter app move onto the Rust orchestration
   crate (M8), or do Dart and Rust implementations coexist? Coexisting doubles
   the G25 surface for the protocol's hardest paths; moving means rewriting the
   parts of `AppState` that drive sync.
2. **Who owns storage and transport.** An SDK-owned encrypted SQLite and HTTP
   stack keeps the atomicity rules in one place but adds Rust dependencies
   (SQLite with a cipher, TLS, an async runtime) that need license and audit
   review. Host-provided storage is lighter but makes every host's store part
   of the review.
3. **Service identity and consent.** Who may add a bot to a conversation, how
   members are told, whether bots may be in DMs, and whether a provisioning
   backend is acceptable at all under the product's privacy claims.
4. **State size.** Every transition re-seals the whole provider state
   (`_sealNext`, up to 32 MiB by `MAX_STATE_BYTES`). Fine for a phone; a bot in
   hundreds of groups may need per-group sealing, which is a crypto change.
5. **Push for embedded apps.** Each app has its own FCM/APNs credentials; the
   server's provider configuration is per instance today.
