# K2 native state migration and next slice

**Native slice implemented, 2026-10-27; full K2 remains unwired.** The
internal `history.rs` primitives were independently reviewed, then the native
transfer map, v2/v3 state reader and v3 writer were implemented with the
coordinator's review corrections. See [native evidence](../../testing/evidence/K2-native-state.md).
Public FFI/ABI v7 and release gates remain unchanged. Review the final native
delta before adding transfer FFI or application persistence.

## What must survive a restart

An approved link cannot recreate its claimed device identity after a crash.
Keep one sealed native identity throughout reserve, claim, completion and
history import. K2's client-generated credentials and exact retry protocol
are specified in [the main design](K2-new-device-history.md); saving native
keys alone is insufficient to recover a lost response.

The encrypted local database owns HTTP credentials and local file/download
progress. The sealed native state owns transfer private keys, the secret
link-derived handoff key and source file keys. Neither ownership crosses
the FFI as an unencrypted private-key export.

| Data | Owner and lifecycle |
|---|---|
| New signing identity/OpenMLS records | Native state, retained as the new active device after promotion |
| Transfer private key | Native incoming-transfer record; erased on durable import completion, cancel or expiry |
| `K_link` | Native pending-transfer record, both directions; same cleanup as above |
| Source FK32/nonce8 | Native outgoing-transfer record once a snapshot is encrypted; retained until ACK, cancel or expiry |
| Claim token, device secret, initial session token | Encrypted pending-enrollment record before claim; promoted/retained only where needed by session or transfer |
| Frozen signed claim request | Encrypted pending-enrollment record; exact retry, never regenerate key package/signature inputs |
| Authenticated handoff ciphertext | Encrypted transfer metadata or native bounded record; safe to retry/open again while its private context exists |
| Blob IDs/digests, ciphertext path and range offset | Encrypted local transfer metadata; never a plaintext snapshot file |
| Finalized/import ledger | Encrypted local database, in the same commit as the relevant state/import transition |

## Envelope v3, preserving v2

Keep the existing authenticated outer header order exactly:

```
"PMMLSST1" | u16 format_version | u64 counter
| lp(account_id) | lp(device_id) | lp(signing_public_key)
| nonce12 | u32 ciphertext_length | ciphertext
```

`lp` is the existing u16-big-endian byte length. AES-256-GCM AAD remains the
entire header through `nonce12`, as in v2. `ciphertext_length` must equal
the remaining bytes, without trailing data. Identity, state-key length,
counter/minimum-counter and total-size checks remain mandatory.

V2 plaintext remains exactly `encode_records(provider.storage.values)`.
Restore v2 with its existing decoder, an empty transfer map and a flag that
the handle has legacy serialization. Never reject/reset a valid v2 state
merely because K2 is installed. Format v1 and unknown future versions still
fail closed. A failed open leaves the existing protected record untouched.

V3 plaintext uses an explicit typed wrapper:

```
"PMMLSPL3"
| u32 provider_records_bytes_length | provider_records_bytes
| u16 pending_transfer_count
| pending_transfer_record...
```

`provider_records_bytes` is the unchanged v2 `encode_records` encoding.
Retain its existing record-count, key/value-length, duplicate-key and exact
end-of-input checks. An unknown wrapper, invalid sublength, duplicate native
transfer key or any trailing bytes rejects the whole restore before a
partially reconstructed handle is returned.

The first implementation caps the map at **16 pending transfers per native
device** and each encoded transfer record at **12 KiB**. This is an internal
parser/resource bound, not a new public device limit. Exceeding it refuses
another transfer; it never silently evicts a valid transfer. The current
32 MiB native-state envelope ceiling still applies to the combined content,
including provider records. Map order is lexicographic by canonical origin
then link ID so equal logical states have one plaintext representation.

### Typed transfer record

Each record starts with `u32 record_length` and contains the following
canonical fields in order:

```
u8 record_version (=1)
| u8 direction (1=outgoing/source, 2=incoming/recipient)
| u8 status
| lp(canonical_origin) | lp(link_id) | lp(account_id)
| nonce32
| lp(source_device_id) | source_signing_key32
| lp(recipient_device_id) | recipient_signing_key32
| transfer_public_key32 | transcript_hash32
| u64 original_link_expires_at_ms | u64 approval_intent_at_ms
| u64 approved_at_ms | u64 expires_at_ms
| sas_mac_prefix4 | claim_tag32 | approval_tag32
| K_link32
| u8 transfer_private_present | optional transfer_private_key32
| u8 source_bundle_present | optional source_bundle_material
| u8 verified_handoff_present | optional verified_handoff_sha25632
```

The record version and direction/status enums are closed. IDs are nonempty
and at most 128 bytes, origin at most 2048 bytes, both device IDs/signing
keys must differ, and the account must equal the outer native identity.
The outer device must be the source for direction 1 and recipient for
direction 2, with the corresponding outer signing key. These invariants
prevent restoring someone else's transfer into an otherwise valid identity.
The map key is the record's `(canonical_origin, link_id)`; it cannot be
supplied separately or duplicated. Native code receives an already
canonical locally configured origin and retains its exact bytes.
The nonce permits exact transcript reconstruction after restart. The saved
SAS prefix and tags preserve the original verification result after the raw
scanned secret has been erased; `K_link` cannot derive keys from the other
domain-separated HKDF labels. Validate the saved transcript hash against
the reconstructed context and the displayed SAS against its four-byte prefix.

Outgoing records must have no transfer private key. Incoming records require
exactly one 32-byte transfer private key and no source bundle material.
Restore validates the private/public pair through a local HPKE seal/open
self-check before accepting the record; it does not export the private key
or ask the server to validate it. Source bundle material is:

```
FK32 | nonce_prefix8 | u64 snapshot_counter | header_sha25632
| ciphertext_sha25632 | u64 ciphertext_size
```

Validate nonzero counter, the K2 ciphertext cap and exact lengths. Do not
place the snapshot plaintext or HTTP credentials into this native record.
The source ciphertext file itself is handled by the app's existing private
working directory and recorded by digest in the encrypted local database.

Statuses describe the allowed native transitions, not arbitrary server
state strings:

- Incoming: `claimed_waiting_approval`, `approved_waiting_handoff`,
  `handoff_verified`, `importing`. The app's durable import ledger decides
  completion, followed by the native cleanup transition.
- Outgoing: `verified_waiting_approval`, `approved_waiting_snapshot`,
  `snapshot_ready`, `handoff_posted`. A failure retries identical frozen
  context; a replacement public key requires a new link.

For each direction the four listed statuses encode as 1, 2, 3, 4 in that
order. Reject 0 and all other values. Both optional-presence bytes accept
only 0/1 and must agree with direction and status; `source_bundle_present`
must be 1 for outgoing `snapshot_ready`/`handoff_posted` and 0 in its earlier
states. This prevents an authenticated but internally inconsistent record
from being treated as resumable work.
`verified_handoff_present` is 0 for every outgoing record and incoming
waiting/approved records, and 1 for incoming handoff-verified/importing
records. Once present, only that exact opaque handoff digest may reopen.
Reopening during importing retains that status so a crash before the durable
database import can recover plaintext without rolling the state backward.

Before approval, `approved_at_ms` is zero and active expiry is the original
link expiry. The source's SAS-confirm operation freezes
`approval_intent_at_ms` while that link window is live; its encrypted native
state and exact outgoing approval request must commit **before** HTTP sends
the approval tag. Repeating confirmation cannot change that timestamp.
Incoming records require zero intent time. An outgoing confirmed-approved
record requires a previously committed positive intent time no later than
original link expiry.

A waiting context remains sealed for recovery until
`original_link_expires_at_ms + 7 days`; it does not remain active for normal
operations. After original expiry, no new claim/SAS output, source approval
POST, handoff open/seal or snapshot may start from waiting state. Only a
valid locally expected approval tag can recover that context, with a
positive `approved_at_ms <= original_link_expires_at_ms`, approval time no
later than current time, and current time strictly before approval time
plus seven days. Source recovery additionally requires the already durable
local user intent. The recipient may authenticate late approval and use its
persisted identity/device secret with ordinary password sign-in if the
initial completion window expired; it must not recreate the initial session.

Once approval is authenticated, set approval time and fixed transfer expiry
once. Retrying cannot extend either deadline. A native operation receives
the app's current UTC time explicitly; expired active records cannot
open/seal another handoff even if the server says pending.
Do not rely on wall time as rollback detection: the protected state counter
continues to provide that check. Serialize expired records until cleanup
commits so merely reading a sealed record never mutates it silently.
Keep `original_link_expires_at_ms` immutable even after approval changes the
transfer deadline. Exact native incoming/source claim retries check it and
the complete frozen context/secret and return the existing public result
without regenerating a key. Source snapshot-material retries in ready or
posted states accept only an exact match of key, nonce, counter, hashes and
size, preserving the existing stage. Before posting a handoff the app must
durably freeze its opaque bytes: HPKE re-sealing is randomized and cannot
serve as an exact server-resource retry.

## Atomic persistence and upgrade rules

All active-device transfer mutations go through the existing serial native
service and expected-counter database transaction. A transfer update must
not reseal an old in-memory MLS snapshot after a concurrent sync event.
Persist the new sealed state and its incremented counter using the existing
atomic state/cursor rules. Keep the cursor unchanged for transfer-only
mutations. The caller must restore the committed state on transaction
failure, just as for existing MLS transitions.

Restoring v2 does not eagerly overwrite disk. The next normal state commit,
or an explicit serialized upgrade operation, writes v3 at counter N+1
against expected N. Commit failure preserves the exact v2 protected record.
Subsequent v3 restores enforce that counter normally. An old binary that
does not understand v3 must refuse it, never downgrade or reset it.

Before first v3 claim, seal the newly reserved identity and incoming transfer
record into the encrypted pending-enrollment row, with a fresh existing
32-byte state key and initial counter 1. This row is separate from the
active account/session tables. The signed request and all three raw initial
credentials already exist there before any claim POST.

After the authenticated completion receipt, **one local transaction**:

1. Checks pending row identity, origin, claim digest, receipt and counter.
2. Requires no conflicting active identity.
3. Writes the active Session using the local initial token/device secret,
   the same sealed native state/key/counter, and initial cursor zero.
4. Writes a promotion ledger keyed by origin/link/request digest, moves the
   claim credential into the encrypted transfer record if still required,
   and removes the obsolete pending-enrollment row.

On restart, a matching promotion ledger/active identity means promotion
already happened. Resume only the history transfer; never overwrite a newer
active sealed state/cursor with its old pending snapshot. A conflicting
active identity is an explicit local recovery error, not replacement.
Crash before the transaction retains the complete pending row and exact
completion retry. Crash after it retains the complete new active identity.

After import, commit the import ledger and history first. A serialized native
cleanup commit removes the transfer's private material before/with the app's
final ACK bookkeeping; if the app crashes in between, the import ledger
permits an idempotent cleanup/ACK without reimporting or creating a new key.
ACK loss cannot roll back the ledger, extend expiry or resurrect private
records. Server cleanup is idempotent and does not require retaining local FK.

## Concrete fixtures and tests to add with implementation

Do not synthesize an alleged v2 fixture with the new v3 encoder. Generate a
fixture through the current v2 code before changing it:

1. Construct two synthetic `MlsDevice`s with fixed account/device labels;
   create a group, add the second member, exchange one encrypted application
   message, and seal the first device with synthetic state key `[0x71;32]`
   at counter 41. Record the state envelope and its SHA-256 as a binary test
   fixture; no real account, host, token or user message is involved.
2. Alongside that fixture store the peer state and a next-message ciphertext,
   generated through the same old code, so the upgraded device must both
   decrypt that message and send a message the old peer decrypts. Retaining
   the signing public key alone is not enough evidence that provider state
   survived.
3. Under the new reader open the fixture with minimum counter 41; require
   empty transfer map, original signer/group epoch and successful exchange.
   Re-seal v3 at 42, reopen with minimum 42 and repeat the exchange.

Synthetic fixture keys are for tests only. Do not print any application
private state or put real keys into evidence. The test fixture generation
command and digest go into evidence when the fixture actually exists; this
fixture now exists under `crypto/rust/tests/fixtures/state-v2/`; its archived
generator, manifest and regression test provide that evidence. The recipe
above describes generation before the writer rewrite.

Additional required native/parser tests:

- V2→v3 with zero, one incoming and one outgoing record; stable v3 canonical
  serialization; distinct device identities and source/recipient context.
- Wrong state key, wrong account/device/signing header, counter below the
  minimum, format 1/future version, invalid wrapper and every truncated prefix.
- Oversized provider section, transfer count >16, record >12 KiB,
  duplicate map keys, invalid enums/options, outgoing private key,
  incoming missing private key/source file key, inconsistent keypair,
  wrong device role and trailing bytes.
- Existing provider duplicate-key/record limits remain effective inside the
  wrapper. Validate all records before exposing a reconstructed native handle.
- Every transfer mutation followed by state re-open; native private keys and
  secret context survive only until cleanup, while signing/group state and
  sync cursor remain correct.
- Failed expected-counter commit, full disk, stale in-memory handle, crash at
  each pending-enrollment/promotion/import/cleanup boundary, repeated exact
  claim/completion receipt, and a completed session that is revoked/rotated/
  expired. No re-created session or cloned identity.
- An already promoted active identity with newer counter/cursor must never
  be replaced by a retried pending promotion or an old state envelope.

## Next ownership slices after W8 checkpoint

1. **Native state implementation:** `history.rs` private pending-record
   codec/restore helpers plus `mls.rs` and `mls/state.rs` integration and native
   tests. No FFI or app changes yet. Generate the genuine v2 fixtures first;
   independently review the version migration and failure/cleanup tests.
2. **ABI and binding contract:** next additive ABI after v7, bounded transfer
   functions and domain-separated v3 enrollment proof. Header, FFI and Dart
   bindings change together only after exact signed bytes and ownership
   semantics are reviewed. Release availability remains fail-closed.
3. **Server protocol resource:** reserve/claim/completion idempotency and
   temporary ciphertext lifecycle in new dedicated files/migrations, with
   authorization/revocation/expiry tests. Coordinator allocates migration
   numbers after W8/community work.
4. **App persistence/import:** encrypted pending enrollment/promotion,
   history-only export/import and provenance/timeline union, on the final
   W8 schema and with one coordinator for generated Drift files.

The current agent can own slice 1 after clearance. Other workers may review
or implement the disjoint server resource after wire freeze, but must not
edit `mls/state.rs`, the shared crypto binding or generated local schema at
the same time. None of these slices alone establishes a usable K2 feature.

Two server wire constraints must remain explicit during slice 3: the signed
claim JSON supplies its canonical `server_origin` (the server validates HTTPS
or demo-loopback spelling but cannot infer it reliably behind a proxy), and
the old/new keyed transcript independently pins each configured origin.
Completion retry checks the exact **current** `sessions.token_hash` row with
the immutable receipt identity and all validity predicates. The ordinary
`PrincipalByTokenHash` fallback for a rotated `previous_token_hash` is not
sufficient; test retry during the existing two-minute rotation grace and
require refusal without touching/recreating the new current session.

Future transfer FFI must withhold the source approval tag until the
SAS-confirm-and-persist intent operation. The internal generic verification
type currently contains both tags for testing, but returning that whole
object as a source-side public HTTP-ready result would bypass this ordering.
Raw scanned secrets are erased; bounded recovery retains only the encrypted
native transfer context/key and `K_link`, with the frozen verification result.
