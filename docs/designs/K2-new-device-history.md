# K2: history on a newly linked device

**Status: reviewed design; implementation in progress, 2026-10-28.** This
document specializes the reviewed K0 design after L0. Independent security/migration reviews cover the native preparation and v3
enrollment slices; each remaining slice still requires review and checks. It does not
open a production release gate.

## Scope and current gaps

Build the live-device transfer first. A newly linked device can copy the
history held by the approving device using one encrypted bundle, while both
devices keep separate MLS identities. This satisfies K2's bundle-or-backup
acceptance line without waiting for automatic backups. K1 later supplies
the alternate recovery-key backup source through the same container/importer.

Confirmed against the current code:

- L0 authenticates both ordered signing keys using the scanned secret,
  canonical origin, link ID, account and nonce. It does not bind a transfer
  key and clears its old-device secret on approval.
- `BackupService.createAndUpload` / `LocalStore.exportBackup` currently
  export the session, device secret, provider state, sync cursor and
  outboxes. `restoreBackup` replaces those records and history. Reusing that
  path for K2 would clone the old MLS leaf; K2 must not call it.
- The encrypted local database holds the decrypted message history, with
  `<sender_device_id>:<action_id>` keys. The chat timeline still starts
  from server envelopes. A new device is denied pre-join epochs, so importing
  rows alone would leave old messages invisible.
- The current native state envelope serializes only OpenMLS provider
  records. A transfer key held in an additional Rust field would disappear
  on sealing unless serialization is deliberately extended.
- The ordinary attachment limit is 48 MiB. The existing backup plaintext
  limit is 64 MiB. A complete history bundle cannot assume it fits the
  attachment route.

## Decisions this design proposes

1. Use K0's fresh transfer key and fresh file key, with the same `VHC1`
   history container. Do not create an account-wide symmetric key.
2. Add device-link protocol **v3**, because the transfer public key becomes
   an authenticated transcript field. V2 remains the documented L0 format;
   it must never be silently treated as history-capable.
3. Stage transfer ciphertext in a separate, quota-charged resource, kept for
   at most seven days after link approval. Download is retryable. Delete
   only after a durable import ACK, cancellation, revocation or expiry.
4. Import history in one database transaction without changing this
   device's session, private MLS state, sync cursor or outboxes.
5. Keep history imported from an own device distinguishable from messages
   this device decrypted directly. The handoff authenticates a snapshot
   made by the old device; it does not create retrospective original-sender
   MLS proofs.

These are proposed security/wire/storage decisions for review, not owner
product decisions recorded as settled.

## Crypto and link transcript

The installed `openmls_traits` 0.6.0 exposes `OpenMlsCrypto` methods
`derive_hpke_keypair`, `hpke_seal`, `hpke_open`, `hkdf_extract`,
`hkdf_expand` and `verify_signature`; `OpenMlsRustCrypto` implements them.
Use those existing APIs and the existing attachment AES-GCM implementation.
No new direct dependency or optional PSK/targeted-message feature is needed.

The new device obtains 32 random bytes from the provider RNG and invokes
RFC 9180 `DeriveKeyPair` for DHKEM(X25519, HKDF-SHA256). Its 32-byte public
key is the final length-prefixed field of the v3 link transcript:

```
domain | version | canonical_origin | link_id | account_id | nonce32
| old_device_id | old_signing_key32 | new_device_id | new_signing_key32
| new_transfer_public_key32
```

All fields keep L0's u16-big-endian length prefix. `version` is
`veritra-device-link-v3`. Origin is locally configured, never server-relayed.
Both devices refuse an absent or incorrectly sized transfer key. V3 uses
the same zero-salt HKDF-SHA256 extraction as L0 and separate expansion
labels `veritra-link-sas-v3`, `veritra-link-claim-v3`,
`veritra-link-approval-v3`, and `veritra-link-handoff-v3`.
The first three retain L0's full-transcript HMAC and eight-digit SAS rules.
The handoff expansion returns the 32-byte secret `K_link`.

The server receives the v3 public key, transcript hash and direction-specific
tags. It receives neither the scanned secret nor `K_link`. The public
locator can retain L0's `SHA256("veritra-link-locator-v2" || s)` construction;
the required protocol version is separately transcript-bound. The manual
code remains the same 26-character secret encoding.

Before sending approval, the old device freezes a locally verified transfer
context containing origin, link/account/ordered device identities,
transcript hash, transfer public key and `K_link`. It then clears the raw
link secret. A later server refresh cannot replace fields in that context.
The new device similarly derives `K_link` before clearing the scanned secret.

## Handoff and bundle

The source takes a consistent history-only snapshot, encrypts a `VHC1`
`kind=2` bundle with fresh FK32 and nonce-prefix8, and uploads ciphertext.
No plaintext temporary file is written. Use bounded snapshot memory in the
first implementation, capped at 64 MiB; fail explicitly rather than silently
omitting old history. Leave the container reader/writer streaming interfaces
so a future measured limit increase does not change the format.

Use K0's canonical `H0` / `H` header. The `enc` and `sealed_fk` fields are
empty for `kind=2`. The exact padded plaintext byte count and chunk count
must agree with framing; each chunk is at most 1 MiB. Bind all chunks to
`"veritra-history-v1" || SHA256(H)` through the existing attachment AAD.
Allocate a fresh monotonic snapshot counter per source device in the same
transaction that captures the export snapshot. Never use the MLS state
counter as a history snapshot counter.

**Reviewed live-bundle framing:** the encrypted plaintext is
`u64-BE payload_length || payload || zero_padding`, rounded up to a multiple
of 64 KiB. The **total padded frame** is at most 64 MiB; the length prefix
and rounding count against that cap. Even an empty payload uses one 64 KiB
frame. `padded_plaintext_size` is this full frame size. The receiver rejects
nonzero padding, a payload length beyond the frame, overflow, trailing
ciphertext and a chunk count other than `ceil(padded_size / 1 MiB)`.
Every chunk length must match its expected plaintext span plus the 16-byte
AEAD tag. K1 backup padding choices remain undecided. This does not alter
any byte of the canonical K0 header layout.

The canonical handoff plaintext contains:

```
version=1, link_id, transcript_hash32, account_id, source_device_id,
recipient_device_id, transfer_blob_id, ciphertext_sha25632,
ciphertext_size, snapshot_counter, header_sha25632, FK32, nonce_prefix8,
optional {rk_pub32, rk_id16}
```

Its HPKE suite is X25519 / HKDF-SHA256 / AES-256-GCM, as in K0. Its `info`
is the unambiguous concatenation of fixed label `veritra-k2-handoff-v1`,
`K_link` and transcript hash. Its AAD is the canonical v3 transfer context,
with a dedicated `veritra-k2-handoff-aad-v1` label. The signer signs fixed
label `veritra-k2-handoff-sig-v1`, transcript hash, and the length-prefixed
HPKE encapsulation and ciphertext. Domain labels are assembled inside Rust;
Dart cannot request arbitrary credential-key signatures.

The receiver first checks the signature against the old signing key pinned
by v3, opens HPKE with the private transfer key and `K_link`, and validates
every contextual field. It checks blob length and ciphertext digest before
importing; header and chunk authentication then bind the snapshot contents.
Unknown versions, missing required fields, duplicate fields, trailing bytes,
overflow, invalid encoding and size/count inconsistencies fail closed.

`rk_pub` is optional when the source has not configured recovery. If present,
derive its ID and require the exact supplied `rk_id`; import it only through
this authenticated handoff. Never replace a different already-configured
recovery identity as a side effect. K2 live transfer works without RK and
does not enable automatic backups without completing K1 setup.

## Native state and restart behavior

Use the next available additive ABI version after L0/W8 integration. Add
opaque operations for transfer-key creation, handoff seal/sign, handoff
verify/open and transfer cancellation. Private X25519 keys never cross FFI.
The open operation returns the bounded validated handoff fields, not the
private key. Clear owned plaintext/key buffers after use.

Extend the native state envelope explicitly to hold pending transfer records
(link ID, transcript hash, recipient keypair, deadline and status) alongside
OpenMLS records. Continue reading the current state-envelope v2; write the
new version after a successful open. Do not reject or reset existing v2
device state merely because K2 was installed. Keep format-v1 rejection and
all minimum-counter/identity checks. Test upgrades with real v2 state.

Before a new device posts a v3 claim, persist a separate encrypted pending
enrollment record with its sealed native state, state key/counter, origin,
identity, frozen signed claim request and the **locally generated** completion
credentials specified below. This is not an active session. The server must
not generate those credentials only in a response: doing so would strand
the reserved identity if either the claim or completion response were lost.
On successful confirmation, atomically promote the pending record to the
active session/crypto record, retaining pending transfer state. A retry must
never regenerate the reserved device's signing key.

The old device stores its outgoing verified context and upload progress only
inside the encrypted local database. An ambiguous approval/post response
retries the identical context and handoff; it cannot take replacement keys
from a new server response. The new device persists the verified incoming
context and ciphertext download offset. Cancel, expiry, durable completion
or local reset wipes the relevant secrets and transfer key records.

## Idempotent v3 enrollment and completion

V3 changes claim/completion credential ownership deliberately. Each secret
is 32 independent random bytes encoded as canonical unpadded base64url:
`claim_token`, `device_secret`, `initial_session_token`. They are generated
on the new device and durably saved in its encrypted pending record before
the first claim request. Hash them with the existing `auth.HashToken`
construction: SHA-256 over the exact canonical token text, represented as
64 lowercase hexadecimal characters. Never derive one credential from
another, the link secret, a device key or a public locator. Raw credentials
are not returned by the server or stored there.

### Reservation before key generation

Before calling claim-enrollment, save `{canonical_origin, locator,
reservation_request_id}` locally. The request ID is a fresh random 32-byte
value encoded as lowercase hex; it is an idempotency key, not a bearer that
grants a session. A v3 reserve request contains:

```
{code: locator, protocol_version: "veritra-device-link-v3",
 reservation_request_id: hex32}
```

In one transaction the server reserves the final account/device IDs and
challenge and records the request ID on the link. The same locator/request
ID returns exactly that existing reservation and challenge while the link
is unexpired and pending/claimed. A different request ID cannot replace a
reservation. Returning this public preflight to an exact replay does not
reveal a private key or credential. Do not create another device or challenge
on a lost-response retry.

The new device creates its signing identity only after this preflight, then
durably writes the sealed identity before submitting its proof. If it
crashes before the identity was committed, it has not yet claimed the
device and may finish that unclaimed reservation after the user rescans the
same QR. Once a sealed identity/claim request exists, recovery always opens
that exact saved identity. Do not store the raw scanned secret merely to
make preflight resumable; rescan is acceptable before the signed claim exists.

### Claim request and proof binding

The v3 claim JSON contains the existing `code`, `device_name`,
`enrollment_reservation_id`, `device_key_package`, `signing_key`,
`transcript_hash` and `claim_tag`, plus `protocol_version`, `server_origin`,
`reservation_request_id`, `transfer_public_key`, `claim_token_hash`,
`device_secret_hash`, `initial_session_token_hash`, and `challenge_signature`.
It contains no raw token, device secret, session token or approval tag.
Validate all hash encodings and exact public-key/tag lengths before storage.
`server_origin` is the claimant's exact canonical locally configured origin;
the server includes that received value in proof verification rather than
reconstructing it from forwarded headers. It rejects noncanonical values.
Accept only canonical HTTPS origins, or HTTP origins whose host is exactly
localhost/a loopback IP under the existing demo transport rules; reject
userinfo, path other than empty, query and fragment. Match the client's
canonical scheme/host/default-port spelling exactly, with no trailing slash.
The old device independently compares its own configured origin through the
keyed transcript; the claim field does not grant authority over another
origin or change a server setting.

The proof is Ed25519 under the reserved new signing identity. Rust constructs
the following canonical message: the domain is raw, the next eight fields
have u16-BE length prefixes, and the final eight fields are fixed 32 bytes.
The signed device name is valid UTF-8, nonempty, at most 64 UTF-8 bytes and
has no leading/trailing whitespace. It is never normalized after signing.

```
raw("veritra-device-link-enrollment-v3")
| LP(canonical_origin UTF8) | LP(locator lowercase-hex TEXT)
| LP(reservation_request_id DECODED32) | LP(link_id UTF8)
| LP(account_id UTF8) | LP(new_device_id UTF8) | LP(device_name UTF8)
| LP(server_challenge)
| FIXED(new_signing_key32) | FIXED(SHA256(key_package_bytes))
| FIXED(transfer_public_key32) | FIXED(transcript_hash32) | FIXED(claim_tag32)
| FIXED(claim_token_hash32) | FIXED(device_secret_hash32) | FIXED(initial_session_token_hash32)
```

Here hashes are decoded 32-byte values inside the signed message, not their
JSON hex text. `protocol_version` is fixed by the domain and v3 transcript.
The server checks all reserved fields, challenge and Ed25519 proof, then
computes/stores the canonical claim-message digest as `claim_request_hash`.
First success freezes the key package, identity, transfer key, transcript,
MAC, credential hashes and exact request digest and moves pending→claimed.
The proof and request are persisted locally before the network call, so a
lost response is retried byte-for-byte; it cannot mint another key package.

An exact proof/request retry is accepted in claimed/approved/consumed states
and returns only the same public link acknowledgement, subject to account/
device revocation and the completion/transfer deadline. A different request
digest, key or credential hash is a conflict and never mutates the original.
An exact retry does not reset counters, deadlines or recent-auth timestamps.
No response introduces a new secret that the client must somehow save.

### Poll, completion and local activation

For v3, `GET claim-status` is read-only. It authenticates the persisted
`claim_token` in the existing header, compares its hash, and returns
pending/approved/completed state and bounded public identity/transcript/
approval-MAC fields. It never creates or rotates a session. JSON redirects
remain disabled. Polling after a lost response is safe.

After verifying the approval MAC and all locally pinned context, the client
posts `/device-links/{id}/complete` with the claim-token header and body:

```
{protocol_version: "veritra-device-link-v3",
 claim_request_hash: hex32, transcript_hash: base64_32,
 initial_session_token_hash: hex32}
```

All three body values must match the immutable claim. In one transaction,
approved→consumed inserts the **precommitted** session hash using normal
session idle/absolute lifetimes and records a completion receipt containing
the session hash, account/device IDs, transcript, request digest and time.
The response returns that public receipt and approval MAC, **never a raw
session token or device secret**. The client constructs its Session using
its locally saved initial session token, device secret and pinned origin.
It compares the receipt with its saved hashes/identity/transcript before
the atomic local session/crypto promotion.

On an exact completion retry in consumed state, return the same receipt
only when that exact existing session remains active, unexpired, unrevoked
and unrotated under the normal session lookup rules. Do not INSERT again,
touch/extend its lifetime, replace another token, or follow a rotated token
to disclose a replacement. If the session was deleted, rotated or expired,
return a terminal session-unavailable result; replay must never resurrect a
logged-out or revoked session. The client still has its original private
identity and device secret, so normal password sign-in can establish a new
session when allowed, then it can resume the pending history transfer.
This requires a direct current-row lookup inside the completion transaction:
`sessions.token_hash = initial_session_token_hash`, matching receipt account
and device, plus the usual idle/absolute expiry and account/device validity
predicates. Do **not** call `PrincipalByTokenHash` as the sole check: its
normal rotation-grace fallback accepts `previous_token_hash` for two minutes.
An initial token present only as a rotated-out alias must be refused even
inside that grace. Do not mutate a new current session through that alias.

The claim credential remains scoped to this link and recipient until the
seven-day completion/transfer deadline or explicit cleanup; it cannot create
a second initial session. A first completion must occur within the approved
link window. A retry of a completion that already committed may retrieve its
receipt within that transfer deadline, without extending the original
session. Revocation/cancellation overrides both windows. Persist the receipt
on the server before answering, and retain the encrypted local pending
record until local activation commits. If the local commit succeeds but ACK
is lost, startup finds the same active identity and resumes only the transfer.

This is a versioned v3 route/state change. Preserve v2 behavior only on
explicitly v2 links; a v3 client must never fall back to the response-generated
v2 credential path. Neither idempotent route stores plaintext credentials.

## Server resource and lifecycle

Use the existing blob interface and deletion queue. Add a temporary
`device_history_transfers` resource rather than disguising the bundle as a
conversation attachment. Store only link/account/source/recipient IDs,
ciphertext reference/digest/size, bounded opaque handoff, timestamps and
status. The next migration number is allocated at integration time.

- Creation/upload requires the original link-creating device, matching
  account, a v3 approved or consumed link, both devices still active, and
  the stored v3 transcript. Bound the opaque handoff to a small fixed cap
  (8 KiB is sufficient); no arbitrary public-key metadata object.
- Use the existing backup transport ceiling (100 MiB ciphertext) and a
  64 MiB plaintext/container policy. Charge bytes and one blob against the
  account/instance quotas before committing metadata. An upload failure
  cleans its uncommitted blob through the existing deletion queue.
- Allow one committed transfer per link. Repeating an identical digest and
  handoff is idempotent; replacement data is refused.
- Fetch metadata and ranged ciphertext with the pinned claim credential
  or a session for the exact recipient device. These checks remain valid
  after link session consumption; the original ten-minute claim deadline
  is not the transfer deadline. Require both source and recipient still
  unrevoked and the account active.
- Keep GET retryable. **Do not delete on fetch**, which loses history if
  the receiver crashes after download but before commit. ACK requires the
  exact recipient and transfer identity after a successful durable import.
  It removes the handoff and queues ciphertext deletion atomically.
- Expiry (seven days from approval), cancellation, account deletion or
  either device's revocation takes the same cleanup path. A separate
  handoff-completed marker makes a repeated ACK successful without
  retaining the secret fields or granting another download.
- A disconnect or corrupt download does not consume an otherwise valid
  transfer. A new ranged request verifies the same immutable digest/ETag.
  Responses and logs never include key material, ciphertext bodies or
  decrypted history. Rate limits and quota errors use existing patterns.

Suggested endpoints under `/api/v1/device-links/{id}/history`: POST for the
original device's committed upload; GET for bounded metadata/handoff; a
`/content` GET for ranged ciphertext; `/ack` POST for durable completion.
Keep handlers thin and authorization/state transitions in storage/domain
methods. Exact endpoint/encoding details are frozen only after review.

## History-only schema and merge

Define a separate versioned `HistorySnapshot`, not a permissive variant of
`LocalBackupData`. Its allow-list contains conversations and decrypted
message state, reactions, attachment manifests, and current W8 pins/stars/
conversation preferences. It can contain future C7 history keys through an
explicit versioned field once C7 is implemented. Unsupported versions fail
without writing anything.

W8 is currently adding local schema 13 fields `hidden_at`, `format_json`,
`forward_hops`, and tables `local_pins`, `local_starred`,
`local_conversation_prefs`, with backup plaintext v4. K2 must use the actual
merged W8 schema and allocate a new history-only plaintext version; never
hard-code the pre-W8 message projection.

The history snapshot must **exclude** session tokens, device secrets, private
MLS/provider state, state keys/counters, database keys, sync cursor,
processed-MLS markers, unsent messages, both outboxes, drafts, push tokens,
and search-index IDs/content. It does not carry downloaded attachment
plaintext. Existing encrypted attachment manifests may be retained; an
expired/deleted server blob remains unavailable rather than being recreated.

Validate the entire snapshot before a single import transaction. Persist
the import ledger identity `(account, source_device, transfer_id, digest)`
inside that same transaction, then ACK. Re-import of the same transfer is a
no-op. A transfer ID with a different digest is rejected.

For merge conflicts:

- Identity fields (conversation, sender account/device, stable message key)
  are immutable. Conflicting identity or server-ID uniqueness rejects the
  bundle instead of relabeling rows.
- The receiver's existing message state and local choices win. Insert
  previously absent historical rows; never overwrite an existing row's
  body, deletion, hidden state, reaction, pin or preferences from an older
  snapshot. A deletion/hidden tombstone remains body-free.
- Discard expired rows/effects at export and again at import. Preserve
  deletion/hidden semantics so a retry cannot resurrect a message. Never
  import plaintext from an unsupported hidden/action row into a bubble.
- Mark inserted messages with import provenance (source device, transfer,
  snapshot counter/time) and a non-outbox restored state. Never resend
  them or present their transport state as newly delivered/read.
- Populate new FTS entries through the encrypted database's own insert
  path, allocating local search IDs. Do not restore an index or foreign
  search IDs. Hidden/deleted/expired content stays out of search.
- Preserve fresh-device message-request defaults (D48). A snapshot must not
  grant contact acceptance, attachment auto-download or muted-chat alert
  permission that this device has not acquired under the current policy.

The chat timeline needs a history-source union: show imported historical
records even when no server envelope exists. Order by authenticated
snapshot message time and stable key, deduplicate against directly
decrypted rows, and keep newer live rows intact. Imported ciphertext is
never sent through MLS decrypt, and importing never advances the account
sync cursor. Normal membership reconcile adds the new leaf for future
epochs. Conversations with no remaining member able to add it show restored
history read-only, with the existing new-conversation action for future
messages; restoring history cannot grant membership.

### Conversation metadata and membership authority

The snapshot carries only a historical conversation descriptor: its ID,
immutable kind, optional community/channel IDs when that kind requires
them, historical title/icon reference if locally available, and sender
labels keyed by the exact sender account/device IDs. It does **not** carry
an authoritative roster, roles, permission overrides, invite grants,
membership epochs, accepted-request flags or a claim that the recipient is
entitled to join. Validate every message's conversation ID against exactly
one descriptor, its stable sender IDs/key, and its channel context against
that descriptor. Reject duplicate descriptors or inconsistent immutable
kind/community/channel mappings before import.

Keep those descriptors in the imported-history namespace with source
provenance. Do not insert them into the server-synced membership/permission
cache as active conversations. When online, fetch the current scoped
conversation descriptor and member list through the existing authenticated
API. Promote only matching ID/kind/community/channel metadata into the live
view, and only after the normal membership and local MLS Welcome/epoch
checks permit this device to participate. A source descriptor can never
authorize posting, commit processing, attachment fetching, user lookup,
private-channel visibility, moderation or role selection.

If the current server says no membership, the conversation is gone, or a
current member cannot add the new leaf, retain the imported history as
read-only. If offline, mark live membership unknown and keep it read-only
until normal checks complete. A conflicting current immutable descriptor
must quarantine that conversation's historical mapping for user-visible
repair; it must not retarget old messages into the server's different
conversation. A historical channel ID never grants access to a present-day
channel, especially one whose visibility changed.

Current server member names belong only to the current scoped roster.
Source member labels are historical display metadata authenticated by the
own-device snapshot, not proof of current identity/profile/role. They may
label imported bubbles with historical provenance when no current profile
is available, but must not overwrite the current roster, rename contacts,
create members, or resolve unknown account IDs through a less-restricted
endpoint. Removing a user today does not invalidate history the source
already legitimately held; equally, the source's old admin label grants
no current admin action. Existing direct MLS sender bindings remain the
authority for directly decrypted live messages.

## Backup restore alternate (after K1 primitives)

Once K1 provides trusted `rk_pub` enrollment, recoverable `kind=1` VHC1
backups and recovery-key open operations, an already linked device can
select a backup, enter RK locally, and pass the validated history-only
snapshot to this same importer. It needs no recovery enrollment because
the new device already has its own session/MLS identity.

Losing every device is a distinct K1 credential flow: D49 requires password
plus RK, a cancellable wait when a device was recently active, automatic
backups on by default, and new-device enrollment. That flow must complete
before claiming disaster recovery. Its numerical wait/activity thresholds,
recovery-key replacement and backup quota policy belong in K1's reviewed
design; they do not block live K2 transfer.

Do not feed I45 v1 clone backups into the history-only importer or silently
call `restoreBackup`. Legacy clone retirement remains an explicit owner
decision in STATE. Until decided, keep its warning accurate and its code
separate from new-device history copy. Do not label the legacy path as the
new safe restore.

## Prerequisites, owners and implementation files

| Work | Required before live K2? | Why |
|---|---|---|
| L0 implementation/review | Yes | Existing origin/identity and tag checks must remain intact |
| W8 integration | Yes, owner order | Snapshot/import must preserve its final schema and delete semantics |
| Independent review of this design | Yes | Wire, state-envelope, migration and credential boundaries |
| K0 container/native transfer primitives | Yes, build with K2 | Same approved key hierarchy; existing libraries suffice |
| K1 daily scheduling/recovery enrollment | No | Live path uses fresh transfer/file keys and enrolled devices |
| Random RK versus passphrase | Only backup setup | No RK is required for live transfer; do not silently settle owner's question |
| Retire I45 clone restore | Owner decision | Separate compatibility/product decision, not a safe K2 fallback |
| New dependency or external account | No known need | Existing OpenMLS provider, AES-GCM, blob store and encrypted DB suffice |

Proposed implementation ownership after W8 is merged:

- `crypto/rust/src/history.rs`, `mls.rs`, `mls/state.rs`, `ffi.rs`, header,
  ABI pins and native tests: container/handoff primitives and state upgrade.
- New `mobile/lib/crypto/history_transfer_service.dart` and bounded snapshot
  codec; native bindings/service and `CryptoService` capability: transport
  orchestration and exact v3 operations.
- `mobile/lib/storage/local_store.dart`, `encrypted_database.dart` and a new
  history-import module: validated export/merge, provenance and import
  ledger. Allocate schema after W8; regenerate Drift output normally.
- `app_state.dart`, linking settings/connect screens, `message_history.dart`
  and chat timeline: explicit copy progress/resume, durable promotion and
  historical timeline union. Keep main release gate unchanged.
- Server dedicated transfer storage/domain/API files and next migration:
  authenticated temporary ciphertext lifecycle via existing blob interfaces.
- Tests and evidence by layer, then coordinator updates STATE and crypto
  change log. Do not reuse another worker's migration/schema number.

## Acceptance and adversarial verification

The end-to-end demonstration uses two independently enrolled native devices.
The source has pre-link text, replies, edits, deletions, reactions,
attachments, formatting, hidden messages, stars/pins and archived chats. The
new device cannot fetch old server epochs, yet displays/searches permitted
copied history and exchanges future MLS messages while the old device
continues sending. Verify its signing key and leaf are distinct and the
source session/state never appear in the bundle.

Required adversarial matrix:

- Every origin/link/account/device/signing/transfer-key field changed; wrong
  secret; v2 downgrade; missing or reflected tags; forged handoff/signature;
  wrong HPKE info; changed header, digest, size, chunks, order or truncation.
- Restart/crash at pre-claim persistence, approval response, handoff post,
  every download range, validation, import transaction, post-commit ACK,
  deletion queue and state-envelope upgrade. Repeat every API operation;
  no cloned identity, lost valid retry, partial import or duplicate row.
- Drop each reserve/claim/complete response after its server transaction,
  restart the client from the durable pending record, and retry exactly:
  reservation/device/challenge/credential hashes remain identical; no new
  key package or session is generated. Change each signed request field and
  credential hash independently and require conflict. Replays never extend
  reservation/link/session expiry or recent authentication. Revoke, rotate,
  log out or expire the completed session and prove completion replay cannot
  reinsert it. Scan server storage/responses for raw initial credentials.
- Revoked source/recipient, wrong-account/other-device access, expired link
  versus unexpired transfer, transfer expiry, quota/full disk, cancellation,
  empty/corrupt/oversized snapshots and malicious collection counts.
- Import over newer live messages, newer edits/deletes, local hide/star/
  archive choices, conflicting identity, duplicate server IDs, expired
  targets and repeats after expiry. Cursor, outboxes, native state and
  encrypted database key must be byte-identical across import.
- Old messages visible without historical envelopes; future messages decrypt
  under the new leaf; a read-only orphan conversation never sends; message
  requests remain gated; FTS excludes hidden/deleted/expired text.
- Historical roster/admin-name injection, renamed/removed members,
  unavailable membership, mismatched immutable conversation/channel mapping,
  and offline import never change current roles or authorize any live route.
  Source labels remain provenance-only; current member names are fetched
  only through the current conversation's scoped endpoint.
- V2 native state upgrade, cross-platform sealed-state/pending-record paths,
  no secret in requests/logs/backup export/temporary plaintext files, retained
  ciphertext quota, and cleanup after durable ACK.
- K1 alternate later: wrong RK, account/header/source mismatch, replayed old
  backup, local newer state and interrupted import all use the same merge
  rules and never replace the linked identity.

Narrow tests precede full `scripts/test` and `scripts/lint`. Current Windows
full-suite cleanup/fsync failures are recorded by L0; they must not be
mistaken for successful K2 validation. This design reports code inspection,
not an implemented or tested K2 feature. Claude Opus was unavailable for
this session; an available independent agent prepared this draft for review.
