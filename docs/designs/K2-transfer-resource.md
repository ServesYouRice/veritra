# K2 transfer resource: wire and ownership

2026-10-28. Reviewed design, implemented server slice awaiting final diff review. The v3
enrollment authentication slice is separately reviewed; this resource does
not create sessions or change MLS state. No dependency is needed.

## Wire

Base: `/api/v1/device-links/v3/{id}/history`. All responses use
`Cache-Control: no-store`. JSON byte fields use standard padded base64;
digests and client-generated transfer IDs are canonical lowercase hex32.

POST uses streaming `multipart/form-data`, exactly two parts in order:

1. `metadata`, `application/json`, at most 12 KiB, strict known fields:
   `protocol_version:"veritra-device-link-v3"`, `transfer_id`,
   `claim_request_hash`, `transcript_hash` (32 bytes),
   `ciphertext_sha256`, `size_bytes` (1..100 MiB), `handoff` (1..8192 bytes).
2. `ciphertext`, `application/octet-stream`, exactly `size_bytes` bytes.

Reject extra parts, wrong order, malformed metadata and oversize bodies.
Use `MultipartReader`, not a disk-spooling form parser. The blob interface
streams ciphertext; SQL never receives the ciphertext body. Compute the
actual digest/size through that interface and require the declared values.
The server neither parses the container nor trusts a declared plaintext
size. Native validation enforces the 64 MiB plaintext/container policy.

Only the original source device's active account session may POST. Require
the stored claim digest/transcript and approved/consumed v3 context. One
immutable transfer per link. An exact metadata retry returns the same
receipt; different ID/digest/size/handoff conflicts. Compare the handoff by
its persisted SHA256 even after erasing its bytes. A replay need not store
or re-read another ciphertext body once its immutable metadata matches.
Return 201 first commit, 200 exact retry:

```text
{transfer:{transfer_id,link_id,account_id,source_device_id,
 recipient_device_id,claim_request_hash,transcript_hash,
 ciphertext_sha256,size_bytes,state,created_at,expires_at,acked_at?}}
```

GET metadata returns the same receipt plus opaque `handoff` only to the
exact recipient. The exact source may read status/receipt without receiving
the handoff. Missing resource is 404; terminal state returns its receipt
without handoff/content. The server never returns its private storage key.

GET `/content` requires exact recipient authorization and active state.
Use existing `serveEncryptedBlob`: verified chunk record, immutable
`ETag: "sha256-<digest>"`, byte ranges/If-Range, 206/416 and no consumption.
Resume bytes against the same ETag and verify the whole ciphertext locally.
No recovery lease/offset is used: this transfer is deliberately retryable.

POST `/ack` strict JSON `{protocol_version,transfer_id,ciphertext_sha256}`
requires the exact recipient. The client sends it only after its import
transaction and import ledger commit. The server cannot prove local import;
it records the authenticated assertion. Atomically mark acknowledged,
erase handoff/storage reference/chunk record and queue blob deletion.
Exact replay returns 200 with the same acknowledged receipt. Mismatched
identity/digest conflicts; no terminal state can revive downloadable data.

DELETE cancels the copy for the exact source or recipient, returns the
terminal receipt, and repeats idempotently. It never unlinks/revokes the
recipient device. An acknowledged transfer remains acknowledged.

Recipient authorization is either an ordinary session for exactly the
stored account/recipient device, or the canonical 32-byte claim header
`X-Veritra-Claim-Token` hashed and matched to this link. A malformed or
incorrect supplied session must not silently fall back to another identity.
Source routes always require the source's ordinary session. Claim auth
never uploads or obtains another session.

All operations recheck active account, unrevoked source and recipient, v3
state, and the fixed seven-day deadline from approval. ACK exact retries may
remain idempotent while their tombstone is retained, but expired/revoked
contexts never authorize another download. A first completion still uses
the original enrollment expiry, independent of this transfer deadline.

## Storage, quotas and invalidation

Migration 0039 adds `device_history_transfers`: one link unique; immutable
IDs/context, ciphertext digest/size, opaque handoff plus its digest, private
blob ref/chunk digests, state and timestamps. Terminal rows retain only
bounded receipts/digests needed for idempotency; there are no file keys,
plaintext paths, decrypted snapshot fields or plaintext metadata. Existing
demo rows are untouched.

Active transfer bytes participate in `blob_usage_accounts` and
`blob_usage_instance` through transaction-local insert/update/delete
triggers. Extend `enforceBlobQuota` blob-count query. Initial metadata
commit checks ordinary account/instance byte and blob-count limits, with
normal error codes. An exact committed retry consumes no additional quota.
Do not hide these blobs from account storage reporting or server backups.

ACK/cancel/expiry/account deletion/either-device revocation all use one
storage cleanup helper: enqueue each private storage key, erase secret
handoff/ref and release logical quota in the same SQL transaction. Device
and account cleanup call it before deleting v3 parents. Retention performs
bounded batches (500), expires active transfers at their actual deadline,
then later removes tombstones with ordinary operational retention. Queue
failure rolls back cleanup rather than orphaning a committed reference.

Extend `ListDatabaseBlobReferences` and `RecordBlobChunkDigests` so backup,
restore and verified range delivery account for active transfer refs. Preserve
compatibility when inspecting older database snapshots without table 0039.
No transfer event/push is needed: both devices already poll this resource.

## Crash gap in existing write interface

`uploads.Store.PutEncryptedBlob` currently renames/fsyncs a final blob before
returning its newly generated key. A crash before the following SQL commit
can leave an unreferenced final blob. `CleanupTemporaryFiles` removes only
`.tmp` files. Immediate cleanup plus `QueueBlobDeletion` handles ordinary
errors, but cannot truthfully close that process-crash window.

The reviewed seam is an optional prepared-write capability
implemented by the existing local store. It allocates its random key and
invokes a durable registration callback before creating files. Registration
creates a bounded upload intent with expected size, private storage key and
expiry; intents reserve account/instance bytes and one blob using the same
quota accounting. Successful finalization atomically replaces that intent
with the active transfer reference without double charging. Failed uploads
enqueue/delete their intent; expired intents are enqueued by bounded normal
maintenance. Local `.tmp` cleanup remains in place. Finalization must reject
an expired/cancelled intent, so a delayed writer cannot recreate a removed
resource. Legacy upload methods and existing interface consumers stay intact.
Do not implement a filesystem sweep without a trustworthy live-intent
inventory: it could remove a legitimate in-flight final blob.

The reviewed capability contract is:

```go
type PreparedStore interface {
    PrepareEncryptedBlob(context.Context, func(storageKey string) error) (PreparedWrite, error)
}
type PreparedWrite interface {
    Write(context.Context, io.Reader) (BlobRef, error)
    Close() error // releases the active-write guard; caller owns durable cleanup
}
```

Preparation generates a key and installs an in-process guard before invoking
the registration callback. No file is created before that callback commits
its quota-charged SQL intent. Write is single-use and streams/fsyncs/renames
while guarded; the caller retains the guard through final SQL commit and
then closes it. Local Delete returns retryable `ErrBlobBusy` while a key is
guarded; existing deletion workers already retain every failed delete in
their durable queue. Temporary-file maintenance also skips guarded keys.
This prevents an expiry/revocation delete from being acknowledged before a
late writer renames. After process death, guards disappear while SQL intents
and deletion queue survive; the existing exclusive process lock prevents a
prior writer from surviving into a replacement server instance.

Uploads have a five-minute context/body-close budget. Intents expire at the
earlier of ten minutes and the transfer deadline. No takeover of a live
intent is allowed: an exact concurrent upload gets retryable conflict;
after expiration cleanup queues its key before erasing the intent and a
retry can start a fresh guarded intent. Finalization rechecks current intent,
deadline and both identities, atomically removes its quota reservation and
inserts active metadata. Metadata exact replay after committed finalization
returns the original receipt. An ambiguous SQL commit never triggers direct
blob deletion: retain the durable intent or active reference for exact retry
or maintenance reconciliation, then release the guard. Failures whose SQL
commit is definitely not attempted may queue/erase the intent normally.
Unsupported prepared-write backends fail closed with 503 for this route.

## Ownership and verification

This agent owns new storage/HTTP transfer modules and their
tests, migration 0039, and narrow existing quota/retention/revocation/account/
blob-reference integrations. No Flutter/Rust/STATE edits. Native/mobile
workers must confirm metadata field spellings before their transport wiring.

Required checks: independent HTTP contract; first upload/lost response/exact
retry/changed metadata; wrong source/account/recipient/claim token; all state
and deadline boundaries; digest/size/part/8 KiB/100 MiB limits; mixed existing
blob plus transfer quotas and trigger rollback; ranges/If-Range/corruption;
crash/failed SQL before and after blob creation; ACK/import-response loss;
queue failure/retry; revoked source/recipient/account and expiry deletion;
backup reference inclusion; no handoff or credential/body in logs. Review
the diff independently before declaring this resource complete.
