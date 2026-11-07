# Phase 3: end-to-end encrypted client SDK

**Status: proposed (2026-11-07), not built.** A design only, against `main`
(crypto ABI 13, server migration 0049, local schema 20). It expands the
outline in [`docs/sdk.md`](../sdk.md) and does not repeat it: read §2-§5
there for the layering options, API sketch and service accounts. It
touches credentials, key handling, the crypto boundary and artifact trust,
so it needs an independent review (AGENTS.md) and the owner's answers at
the end before any step is built. Phase 3 starts after phases 1 and 2 reach
working demos (D10). G24 and G25 do not change, and the SDK gets its own
fail-closed gate.

## Summary

- **D19 holds.** Another app becomes a Veritra endpoint by linking the
  SDK. The SDK does MLS, sync, the outbox and payloads *on the host device*.
  There is no widget, iframe or server route that ever sees plaintext,
  because the server has no key to give one.
- **One protocol copy.** A Rust crate `veritra_sdk` above `crypto/rust`
  owns session, store, sync, outbox and codecs (sdk.md option B). Kotlin
  and Swift bindings are generated (UniFFI). The Flutter app moves onto it
  later (owner question 1).
- **Full member, full duties.** An SDK device enforces everything the app
  enforces today: D22, D25, D28, I33, I34, L1 (approved-device list) pins
  and checks, C6 franking, C7 history keys, W7 receive policy. A weaker
  endpoint would weaken every group it joins.

## What changed since the outline (sdk.md, 2026-09-25)

| sdk.md says | Today |
|---|---|
| C ABI 6, then 9 | ABI 13 (C6 report keys and HPKE at 12, C7 primitives at 13) |
| Flutter store v8 | Local schema 20 |
| Whole-state sealing up to 32 MiB (open question 4) | D70 per-group sealed state (format 4, ABI 10): sealing cost grows with one group; a record limit (`PM_CRYPTO_RECORD_LIMIT`) stops sync and offers to leave. Question 4 is answered |
| Non-goals: backup, recovery, linking, communities | These now exist (K0, K1, K2, L0, C0-C8). The SDK still leaves them out of its first release (see Scope) |
| No L1 | L1 (approved-device list) is designed (#133, D94). An SDK device must pin and check lists, and appear on its own account's list |

## Scope of the first SDK release

In: register, sign in, resume, devices and revoke; DMs and groups; every
`VAP1` payload except `callSignal`; attachments; L1 checks; franking on
send and receive; one sync owner; events.

Out, each its own later step: calls, K1 backup and K0 recovery, L0/K2
linking *into* an SDK device (it is a first device only), communities and
channels beyond reading C7 history, admin routes, push wake (owner
question 5).

## API surface

The sketch in sdk.md §3 stands. Additions and changes:

```rust
session.device_list(account_id) -> DeviceListState     // L1: Pinned{version} | Conflict | Missing
session.conversation_state(id) -> ConvState            // Normal | UnapprovedDeviceHeld | ReadOnly
session.report(conversation_id, target) -> ReportId    // C6, sends the franking opening
session.wake()                                         // host push handler; coalesced
enum SdkEvent { ..., DeviceListChanged{account_id}, ConversationHeld{id} }
```

- Plaintext is read through `messages()` only; no event carries it.
- Every call is `async` and goes to the session actor (sdk.md §3,
  "Threading"). Two `Sdk::open` on one `data_dir` fail with `Storage`
  (an OS file lock), never share state.
- Errors as in sdk.md, plus `RecordLimit{conversation_id}` and
  `ListConflict{account_id}`. No variant carries text, keys, tokens or
  ciphertext.

## Key storage in the host app

The host gives the SDK a `SecretStore` (sdk.md §3); the SDK keeps *one*
256-bit database key there and everything else in its own encrypted
SQLite file.

| Host | `SecretStore` the SDK ships as reference |
|---|---|
| Android | Keystore-wrapped key, device-bound, excluded from backup (as D01 and the app's `dataExtractionRules`) |
| iOS, macOS | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Windows, Linux desktop | DPAPI, Secret Service (D26) |
| Server bot | A file readable only by the service user; documented as weaker |

Rules carried from the app, enforced inside the SDK, not left to the host:

- D26: never generate a new key while the database file exists; a missing
  key is `Storage`, never a silent reset.
- The sealed MLS state, rollback counter, cursor, dedupe marker and
  decrypted history commit in one transaction.
- A host store that loses writes or returns a stale value is detected by
  the rollback counter and stops with `StateRollback`.
- The data directory is excluded from cloud backup on each platform; the
  reference stores document it and a test checks it on Android and iOS.

## The crypto boundary reuse

- `veritra_sdk` links `crypto/rust` as an **rlib** and calls
  `mls::MlsDevice` directly. It does not call the C ABI, adds no C ABI
  function, and the Dart binding's exact-ABI rule is untouched.
- Payload, bundle, franking and C7 codecs move to Rust once and are tested
  against the shared vectors in `testing/vectors/` (already read by Rust,
  Go and Dart), so Dart and Rust cannot drift.
- One Cargo workspace and one `Cargo.lock` for `crypto/rust` and the SDK
  crates; `scripts/audit-rust.sh` and the licence metadata follow it.
- Any later change the SDK needs in the core is a normal crypto change: an
  ABI bump if the C ABI changes, and a `docs/crypto.md` entry.

## Platforms

| Order | Target | Package |
|---|---|---|
| 1 | Android (Kotlin, API 26+) | AAR with JNI libs, built by the pinned path of `scripts/build-mobile-crypto.sh` |
| 2 | iOS and macOS (Swift) | XCFramework + Swift package |
| 3 | JVM and Linux bots | Same Kotlin binding, desktop native lib from `scripts/build-desktop-crypto.sh` |
| Later | Plain C header | Only if a host asks |
| Never | Browser, WASM | No device-bound key storage; would invite a server-served page that holds keys |

## Threats

| Adversary | Result | Left |
|---|---|---|
| Veritra server | Learns what it learns from any client; no new plaintext path | As in L2 |
| Malicious or compromised host app | Reads everything its session holds. It *is* the endpoint | Members see the device in the roster and safety numbers; L1 shows whose list it is on |
| Embedding app's backend with a `provision` scope | Can create accounts, never a device: the key and enrollment proof are made on the user's phone | It can create look-alike accounts; usernames and safety numbers are the defence |
| Bot (service account) | Reads the conversations it joined, like any member | Who may add bots is owner question 3 |
| A host that never updates the SDK | Old protocol; mixed-version groups | The server refuses SDK versions below a floor, like the ABI rule in STATE.md's release gates |
| SDK device skipping L1 or C6 checks | Not possible by API: checks are inside the session, not optional | A modified build; same as a modified app |
| Two SDK copies on one data dir | File lock refuses the second | — |
| Host logs SDK events | Events carry ids only | Host logs of `messages()` output are the host's responsibility, stated in the host contract |
| Supply chain (binding generator, crates) | UniFFI and new crates join the G25 review surface | Licence review, `THIRD_PARTY_NOTICES.md` |

## Build steps

sdk.md §7 (M0-M8) is the order. Counters per step; numbers are the next
free ones when each lands, nothing reserved.

| Step | What | Counters |
|---|---|---|
| M0 Workspace and gate | Root Cargo workspace; empty `veritra_sdk`; `Sdk::open` returns `Unavailable` without the `unreviewed-demo` feature; release-readiness gains the SDK check | none; **new dependency** none yet |
| M1 Codecs | `VAP1` (incl. W7 v2), D28 bundle, membership change, franking, C7 codecs in Rust; vectors shared | none |
| M2 Store | SDK's own encrypted SQLite (schema numbered separately from the Flutter app, starting at 1), `SecretStore`, atomic transition, restore on drift | **SDK schema 1**; new deps: SQLite with a cipher, owner first |
| M3 Session and sync | Enrol, resume, catch-up with I33, MLS outbox I34, D28 reconcile, D70 per-group seal, text messages | none; new deps: async runtime, HTTP/TLS, owner first |
| M4 Payloads, attachments, L1, C6 | All payloads, attachments, L1 pins and checks, franking | SDK schema +1 |
| M5 Bindings | UniFFI, AAR, Swift package, samples | none; new dep UniFFI, owner first |
| M6 Server | Service accounts, challenge-signed scoped tokens, per-principal limits, audit, SDK version floor (sdk.md §5) | **+1 server migration**; **+1 crypto ABI** only if the challenge signer must be reachable from the Flutter app too (the SDK itself uses the rlib) |
| M7 Bot sample | JVM or Rust CLI bot | none |
| M8 Flutter on the SDK | Owner question 1 | **+1 local schema** (Flutter data moved into the SDK store) |

## Test plan

- **Parity:** every vector in `testing/vectors/` passes in Rust and Dart;
  a CI job fails if a vector is added for one only.
- **Store:** ported failure-injection tests: crash between seal and
  commit, rollback to an older state, wrong key, a `SecretStore` that drops
  writes, two opens on one directory.
- **Interop:** an SDK test client and the Flutter demo client exchange text,
  edits, deletes, reactions and attachments against `scripts/demo.sh`,
  extending `scripts/test-demo-e2e.sh`.
- **Duties:** with the L1 test-only hook, the SDK device never stages the
  unlisted device and holds a conversation that gains one; a sender
  mismatch becomes `unverifiable`; a report verifies at the server.
- **Server:** Go tests that service tokens fail `withRecentAuth`, scopes and
  conversation lists are enforced in the domain layer, the version floor
  refuses old SDKs, and no token or body reaches logs.
- **No plaintext route:** a grep test that the server has no route or
  handler that decrypts or renders, and the SDK events type has no string
  field for content.
- **Gate:** `Sdk::open` is `Unavailable` in a build without the feature;
  `scripts/release-readiness.sh` still fails for the existing reasons plus
  the SDK gate.

## Open questions for the owner

1. **One copy or two** (sdk.md Q1). **Default: move the Flutter app onto
   `veritra_sdk` (M8)** once M4 passes interop, so G25 reviews the hardest
   paths once.
2. **Who owns storage and transport** (sdk.md Q2). **Default: the SDK owns
   its encrypted SQLite and HTTP stack**, so the atomicity rules stay in
   one reviewed place; accept the new Rust dependencies after licence review.
3. **Bots and consent** (sdk.md Q3). **Default: only a conversation admin
   adds a bot; bots are never allowed in DMs; every member sees a "bot"
   label and a system line when one joins.**
4. **Provisioning backends.** **Default: allowed, account creation only**;
   never a device, never a token that reads.
5. **Push for embedded apps** (sdk.md Q5). **Default: not in the first
   release**; the host calls `session.wake()` from its own push handler and
   sends only generic pushes, as the server does today.
6. **First platforms.** **Default: Android, then iOS/macOS, then JVM bots**;
   no browser target.
