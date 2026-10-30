# K2 ABI8 boundary

Reviewed control/stream framing, implemented 2026-10-29. Controls and bounded
bundle streams have focused checks; final independent stream review and durable
application orchestration remain separate. Existing operations from ABI7, L0
v2 and release gates retain their behavior.
The server wire is pinned in [K2-server-wire.md](K2-server-wire.md), and durable
native records in [K2-native-state-migration.md](K2-native-state-migration.md).
The importer, server resources and application UI are separate work slices.

## Ownership and transaction rule

Rust owns signing identity, MLS records, incoming HPKE private key, K_link,
bundle FK/nonce and verified handoff. No new function exports these secrets.
Dart owns locally generated claim/device/session credentials and immutable
HTTP request bytes inside protected enrollment storage. Generate each independent
32-byte credential using Random.secure(), once, before claim. Persist credentials,
request ID, exact signed request, native state/key/counter and reservation identity
together. HTTP code receives a request only after that commit succeeds.

Every state operation runs through NativeCryptoService._serial, sharing the MLS
operation queue. It loads the current committed state/counter, invokes native,
seals N+1 and commits with expected counter/cursor. Transfer-only commits preserve
the cursor. Failure destroys the mutated handle and restores the preceding
committed snapshot; no result from a failed transaction reaches HTTP or callers.
Initial enrollment uses a separate durable pending identity, not the active row.
Promotion moves that same identity/state/key to active storage atomically.

Native code cannot observe whether a SQL commit reached disk. Passing a counter
or calling seal is not proof of durability. The Dart service is the trusted
persistence boundary; raw bindings are private implementation APIs. Source intent
confirmation returns no approval tag. Only after the intent/state transaction
commits does the service call the separate request accessor and permit HTTP.

## C shapes and local binary framing

Keep PmCryptoHandle, PmByteSlice, PmOwnedBuffer, existing integer errors and
pm_crypto_buffer_free. Add opaque PmHistoryStream and its destroy function.
All new functions return i32, take a device handle plus one request PmByteSlice,
and write one PmOwnedBuffer; stream functions additionally take/return an opaque
stream pointer as specified below. Validate all output pointers (including
aliasing) before state changes. On failure outputs are null/zero. Catch panics,
bound lengths before allocation, and reject unknown enums and trailing bytes.

Each request is raw ASCII `PK2Q`, u8 framing_version=1, u16-BE operation, then
the operation's fields. Each result is `PK2R`, u8 version=1, u16-BE matching
operation, followed by fields. Integers are unsigned BE; B16 means u16 length
and exact bytes; B32 means u32 length and bytes; F32 is exactly32 bytes. No JSON,
base64, implicit terminator, optional trailing fields or platform-sized integers.
An optional value uses u8 0/1 followed by its value only when1. Maximum control
request/result is64KiB; stream data frames are at most1MiB+32 bytes. All UTF-8
strings must decode strictly. Reuse existing internal identity/context bounds.

Common fields:

* ID = B16(canonical configured origin), B16(link ID). Origin max2048 bytes;
  IDs max128. Dart pins its configured origin; never feed response origin into
  this field without exact configured-origin comparison.
* Context = ID, B16(account ID), F32(link nonce), B16(source device ID),
  F32(source signing key), B16(recipient device ID), F32(recipient signing key),
  F32(transfer public key). Incoming begin requires zero transfer key, or the
  previously returned exact key on retry. Native checks local role/identity.
* Verification = F32(transcript hash), F32(claim tag), fixed8 ASCII SAS digits.
  Never includes approval tag, handoff tag or K_link.
* Times are u64 Unix milliseconds. Client supplies its current time, not an
  untrusted server's clock. Original expiry and approved_at come from the pinned
  link response and retain native bounds; exact retries never extend either.

Use the single existing pm_crypto_buffer_free ownership contract, strengthened
with the existing zero-on-drop secret wrapper over the exact owned allocation.
Use it even on Dart decoding exceptions. Do not introduce a second allocator or
free function for sensitive outputs. Input plaintext native allocations are
wiped before free. Dart copies are short-lived Uint8List, overwritten in finally
where owned; this does not promise erasure of arbitrary Dart VM copies. Existing
public buffer_free ownership rules remain unchanged. New result allocations
have their exact final size before copying sensitive bytes; no growth copies.
Rejected overlapping input/output/handle pointers fail before writing outputs
or mutating state; other errors initialize output to null/zero.

## Control operations

Names below have prefix `pm_crypto_k2_`. All fields are in listed order.

| Op/name | Request fields | Result fields and persistence |
|---|---|---|
|1 receive_begin|Context, fixed16 link secret, u64 original expiry, u64 now|F32 transfer public key, Verification. Commit before claim proof/POST; exact retry reuses key.|
|2 source_accept|Context, fixed16 link secret, u64 original expiry, u64 now, F32 claimed transcript hash, F32 claim tag|Verification; never approval tag. Commit before displaying confirmed claim.|
|3 inspect|ID, u64 now|u8 direction, u8 stage, u8 durable-intent-present, u64 original expiry, u64 approved_at, u64 transfer expiry, Verification. No private material. Expired waiting record cannot return verification; late recovery uses op7 directly.|
|4 enrollment_proof|ID, u64 now, B16 locator lowercasehex text64, F32 decoded reservation request ID, B16 device name, B16 challenge, B32 frozen key package, F32 claim credential hash, F32 device-secret hash, F32 initial-session hash|fixed64 signature, F32 claim_request_hash. Uses native stored context/claim MAC/transfer key; verifies own signing identity and exact key-package credential. Name bound64 UTF-8 bytes with no outer whitespace. Persist frozen key package/signature/HTTP body before POST.|
|5 source_confirm|ID, fixed8 typed SAS digits, u64 now|u8 intent_present=1, u64 first intent time. No approval tag. Mutates native intent once; commit state before op6.|
|6 source_approval_request|ID, u64 now|F32 transcript hash, F32 approval tag. Requires source durable-intent state, original live deadline and correct role. Service separately binds persisted claim_request_hash from the exact accepted claim into HTTP. Does not mutate native state.|
|7 apply_approval|ID, F32 approval tag, u64 approved_at, u64 now|u64 fixed transfer expiry. Both roles verify MAC; source requires prior intent. Commit. Bounded late approval recovery follows native design; source cannot issue a fresh approval POST after original expiry.|
|8 source_posted|ID, u64 now|u8 stage=Delivered. Commit after successful/exact-replayed upload response.|
|9 importing|ID, u64 now|u8 stage=Importing(4). Commit may precede DB import; reopening the same handoff/bundle after crash is allowed and preserves stage. Internal native enum4 remains Delivered; direction-aware public decoding calls incoming4 Importing and outgoing4 Posted.|
|10 forget|ID|u8 removed(0/1). Commit deletion only after ledger+ACK obligations, explicit local abandonment or expiry policy. Local forgetting does not revoke device identity or cancel server enrollment.|
|11 expire|u64 now|u16 removed count. Explicit mutation+commit; no hidden read-side expiration.|

Op4 validates KeyPackageIn with the existing provider/MLS1.0 API, then checks
the leaf credential equals this account/device identity and its signature key
equals this native signing key. Native creates the package via the existing
API; service freezes it with pending state before using op4. No caller-only
hash or server-declared identity substitutes for those checks.
Exact proof byte order/hash is the pinned server vector, not this local frame.
No raw claim/device/session credential enters these new native requests.

## Bounded bundle streams

One mutable stream lease per device transfer record, in either direction.
Acquisition reserves the record in the device handle; duplicate begin, forget,
expiry, or another mutation of that record while leased fails. The sole
exception is op9 for the exact incoming record once its stream has fully
authenticated Plaintext mode: the metadata-only Ready-to-Importing transition
keeps its verified digest, key/context and live stream unchanged. A stream holds
no untracked raw device pointer: its device/record lifetime is shared or device
destroy invalidates and wipes all streams. Other transfers and normal MLS ops
remain serialized by the service. Stream destroy releases the lease and wipes
temporary plaintext/secrets; it does not implicitly commit a transfer mutation.

Use bounded in-memory staging first, through chunk-fed/read APIs; no plaintext
file or filesystem path enters the ABI. Frame cap is64MiB TOTAL including the
u64 payload length and deterministic authenticated padding. Ciphertext cap is
64MiB+64*20+416 bytes, matching existing core bounds. Native checks declared
payload length and final total before accepting bytes. Incoming plaintext is
never released until the entire bundle passes expected ciphertext SHA256/size,
header hash/identity/counter, exact chunk framing and all AEAD/padding checks.
This intentionally uses bounded full buffering internally, not constant memory.
Preallocate known sizes instead of growing ciphertext Vec capacity, and bound
native working data to three frame-sized buffers plus8MiB scratch (200MiB).
The first implementation must measure this budget at the cap before claiming
mobile suitability; Dart should hold only its current1MiB transport chunk in
addition to its exporter/importer working data. A single active process-wide
large stream is the initial limit. Future incremental authentication must preserve full verification before
plaintext release and does not change this ABI.

| Op/name | Request/result |
|---|---|
|20 source_begin|Device+ID,u64 now,u64 created_at,u64 snapshot_counter,u8 plaintext_version,u64 exact_payload_length -> stream pointer. Requires Approved source, no previously frozen material. Header account/source come from native context. Recovery key absent for live kind2.|
|21 stream_write|Stream+u64 sequential_offset,B32 bytes(1..1MiB) -> u64 next_offset. Source accepts payload; incoming accepts ciphertext. Wrong offsets/overrun fail without advancing.|
|22 source_finish|Device+stream+u64 now -> B16 transfer_id64,F32 header hash,F32 ciphertext hash,u64 ciphertext size,B32 opaque signed handoff(<=8KiB). Consumes complete payload, freshly seals core bundle, records source material, and retains ciphertext for op25. Source state changes are tentative until service commits with ciphertext cache manifest. No FK/nonce in result.|
|23 receive_begin_bundle|Device+ID,u64 now,B32 handoff(<=8KiB),u8 expected_plaintext_version -> stream pointer plus B16 verified transfer_id64,F32 ciphertext hash,u64 ciphertext size,F32 header hash,u64 snapshot_counter. Verifies source handoff against pinned native context, retains payload secrets internally. Service seals/commits verified handoff digest plus exact opaque handoff before download/import; commit failure destroys stream/restores native state.|
|24 receive_finish|Device+stream+u64 now -> u64 payload_length, u64 snapshot_counter,u8 plaintext_version,u64 authenticated_created_at. The timestamp comes from the authenticated header, never inner JSON; importer compares it with snapshot_created_at. Calls bounded core open with expected identity/digests from verified handoff; no fields supplied from downloaded header become expected authority. No plaintext before success.|
|25 stream_read|Stream+u64 sequential_offset,u32 requested_length(1..1MiB) -> u64 next_offset,u8 eof,B32 bytes. Source returns ciphertext; verified incoming returns sensitive plaintext. Empty bytes only at EOF. Caller can restart a stream after a crash, but cannot seek a live stream backward or change its input.|

The canonical transfer ID is lowercase hex64 of
`SHA256(raw("veritra-k2-transfer-id-v1") || transcriptHash32 || ciphertextSHA25632)`.
The source binds this text as the signed handoff's blob_id; receive_begin_bundle
checks the authenticated ID against the same derivation. Both result IDs must
match server transfer metadata before transport/import. No server-selected ID
or new randomness enters this binding.

`pm_crypto_k2_stream_destroy` releases a stream independently of device destroy.
It takes no request frame. Stream-producing functions write both pointer and
framed metadata only after complete argument validation; on errors neither is
published. Memory handles are process-local, never persisted or sent to HTTP.

## Ciphertext cache and exact publication

Source drains op25 into an application-private ciphertext-only temporary file,
fsyncs it and atomically renames within the same filesystem before committing
native Ready state. The durable encrypted manifest binds ID, ciphertext SHA256,
size, header hash, snapshot counter, exact opaque handoff bytes and cache name.
The database transaction stores that manifest, the exact upload request and
sealed native state together. No upload occurs before cache durability and this
commit. A crash before DB commit leaves an unreferenced ciphertext orphan for
bounded cleanup; a crash after commit recovers the same immutable file/bytes.
The cache never contains an unencrypted snapshot, FK or HPKE private key.

Before every upload/retry, reconcile the file against committed size/digest.
If missing/corrupt after material was committed, do not regenerate a current
snapshot, re-seal a handoff, reuse FK/nonce with different bytes, or replace
the server transfer. This first implementation explicitly abandons that
history copy and reports retry requires a new link/transfer; retain the live
device identity/session and already imported data. A later repair path could
regenerate only an identical precommitted payload digest, but is not part of
this ABI proposal. Delete source cache only after durable ACK/expiry policy.

Incoming may durably cache ciphertext plus the verified opaque handoff, then
resume by feeding the exact file to op21 after native state restore. It can
redownload if that cache is lost. No native decrypted snapshot is written to
disk. App importer consumes verified plaintext chunks in memory and atomically
commits its history ledger; ACK occurs only after the ledger commit. Native
Delivered/importing is resumable and is not evidence of durable application
import. The importer owner defines its transaction/storage API separately.

## Proposed implementation slices and checks

1. Root reviews this exact surface, including package-binding and memory budget,
   before ABI8 changes. Implement local codec and control operations with native
   FFI tests, then ABI/header/Dart bindings together; ABI7 caller version check
   must reject a mixed installation rather than load partially.
2. Implement bounded stream wrappers and ciphertext cache orchestration after
   importer/server contracts converge. Do not declare K2 usable from control
   operations alone. Keep release gates closed.
3. Exercise malformed lengths/enums/trailing bytes/output aliasing, role/context
   swaps, ABI mismatch, no approval tag before source confirmation, lost response
   and disk-commit failure at every state transition, stable signed credential
   retries, two streams for one record, stream/device destruction, ciphertext
   cache loss/replacement, digest mismatch before plaintext, import crash replay,
   zero padding/cap boundaries, and source/incoming plaintext buffer cleanup.

Run native narrow tests then full Rust/fmt/clippy, Dart analyzer/native integration
tests against freshly built ABI8, and repository test/lint scripts. Record
measured memory/caps and platform limitations; no result is done from parsing
or syntax checks alone.
