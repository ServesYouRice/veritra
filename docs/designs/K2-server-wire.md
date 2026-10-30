# K2 server wire: durable device link v3

Implementation contract, 2026-10-27. Source/recipient credentials and sessions
follow the reviewed [K2 design](K2-new-device-history.md). This versioned path
does not change L0 v2 or its routes. Migration 0038 creates a separate
`device_links_v3` table, so a legacy consuming GET cannot operate on v3 data.
Transfer metadata uses the separately reserved migration 0039.

All binary fields in JSON use standard padded base64 (Go `[]byte` encoding).
All hashes/request IDs/locators use 64 lowercase hexadecimal characters.
Raw claim credentials are canonical unpadded base64url of exactly 32 bytes;
only `X-Veritra-Claim-Token` carries the raw claim token. Device/session
secrets never cross these endpoints. Responses never introduce credentials.
Requests/response bodies and secret headers must never be logged.

Base path: `/api/v1/device-links/v3`.

| Method/path | Authorization | Body/result |
|---|---|---|
| `POST /` (without trailing slash) | Existing device, recent auth | `{code,server_origin,protocol_version,expires_in_seconds?}` → 201 `{device_link}` |
| `POST /claim-enrollment` | Public enrollment budget | `{code,protocol_version,reservation_request_id}` → 201 reservation |
| `POST /claim` | Public credential budget; reserved-key proof | Signed claim below → 202 `{device_link}` |
| `GET /{id}` | Original creator device | 200 `{device_link}`; no mutation |
| `POST /{id}/approve` | Original creator device, recent auth | `{protocol_version,claim_request_hash,transcript_hash,approval_tag}` → 200 `{device_link,device}` |
| `GET /{id}/claim-status` | Claim-token header, credential budget | 200 `{device_link}`; never creates/touches/rotates a session |
| `POST /{id}/complete` | Claim-token header, credential budget | `{protocol_version,claim_request_hash,transcript_hash,initial_session_token_hash}` → 200 `{completion,approval_tag}` |
| `DELETE /{id}` | Original creator device, recent auth | Pending/claimed only: cancel enrollment. Already approved conflicts; unlink uses explicit device revocation |

`protocol_version` must equal `veritra-device-link-v3`. `server_origin` is
the source/claimant's exact canonical configured origin: lower scheme/host,
no default port, trailing slash, credentials, query or fragment. HTTPS is
allowed; HTTP is restricted to exactly localhost or loopback IPs. The server
does not fetch it or trust forwarded headers to construct it. Claim origin
must exactly equal the origin frozen by create. Source authentication is
account **and original device**, never another device of the same account.

Create is idempotent for identical locator/source/origin/normalized TTL;
another context conflicts. Default TTL is ten minutes, maximum thirty.
Source/account revocation overrides replay. Reserved IDs/challenge are
stable for the same locator/request ID. A different request ID cannot take
over the link. Reserving again never resets its expiry.

Reservation fields: `id`, `kind:'device_link'`, `account_id`, `device_id`,
`challenge`, `expires_at`, `protocol_version`, `link_nonce`,
`existing_device_id`, `existing_signing_key`.

## Signed claim

Claim JSON fields:

```
code, protocol_version, server_origin, reservation_request_id,
enrollment_reservation_id, device_name, device_key_package, signing_key,
transfer_public_key, transcript_hash, claim_tag,
claim_token_hash, device_secret_hash, initial_session_token_hash,
challenge_signature
```

`device_name` must be valid UTF-8, nonempty, at most 64 UTF-8 bytes, and
equal to its whitespace-trimmed form. Do not normalize a signed value.
The key package is 64 bytes through 48 KiB, signing/transfer keys and MACs
are exactly 32 bytes, and the Ed25519 signature is exactly 64 bytes.

The proof is these bytes, in exactly this order. `LP` means u16-BE byte
length followed by bytes. The initial domain is **raw**, without LP.

```
raw("veritra-device-link-enrollment-v3")
LP(server_origin UTF8)
LP(code lowercase-hex TEXT)
LP(reservation_request_id DECODED32)
LP(link_id UTF8)
LP(account_id UTF8)
LP(new_device_id UTF8)
LP(device_name UTF8)
LP(server_challenge)
FIXED(new_signing_key32)
FIXED(SHA256(device_key_package)32)
FIXED(transfer_public_key32)
FIXED(transcript_hash32)
FIXED(claim_tag32)
FIXED(claim_token_hash DECODED32)
FIXED(device_secret_hash DECODED32)
FIXED(initial_session_token_hash DECODED32)
```

Verify against the reserved identity/context before freezing the first
claim. `claim_request_hash` is SHA256 of this exact message, lowercase hex.
That digest binds the name and every credential/key/hash field. Exact
replays return the public acknowledgement in claimed/approved/consumed
states while their relevant window remains valid. Any changed signed value
conflicts; no replay changes keys, deadlines, recent-auth times or counters.

Independent shared vector: origin `https://example.test`; code `a`×64;
request ID bytes `11`×32; link/account/device `link_vector`, `acct_vector`,
`dev_vector`; name `Vector phone`; challenge UTF8 `vector-challenge`;
signing key `22`×32, key package `33`×64, transfer key `44`×32,
transcript `55`×32, claim MAC `66`×32, credential hashes `77`×32,
`88`×32, `99`×32. Message length 481 bytes, SHA256
`70e1a994b2e4e2878cdab80c38c26012177780bd93b2cacaf73c1699389d6f78`.

## Public state and completion

`device_link` contains ID, protocol, state, source/account/recipient IDs,
canonical origin, nonce, ordered public signing/transfer keys, name, public
transcript/request hash, claim MAC, approval MAC once approved, creation/
expiry/approval/transfer-deadline/completion timestamps. Locator is returned
only to the source create response. It contains no raw credential or secret.

First approval must occur before link expiry; it inserts one device/initial
key package and one durable `device.updated` event, then fixes the seven-day
transfer deadline. An exact retry returns the existing public result without
another device/event, a new deadline or authentication refresh. A different
approval MAC/hash conflicts.

First completion must occur before original link expiry. It inserts exactly
the precommitted session hash with ordinary idle/absolute lifetimes and
atomically records completion. A receipt is:

```
{link_id,account_id,device_id,server_origin,claim_request_hash,
 transcript_hash,initial_session_token_hash,completed_at}
```

On exact completion replay, return the same receipt only while the exact
current `sessions.token_hash` row is valid for that account/device. Check
idle/absolute expiry, active account and both original devices in that same
transaction. Never use rotation-grace alias lookup, insert another session,
extend lifetime or return a replacement token. A deleted, rotated, expired
or revoked session yields 410 `invalid_device_link` with
`state:'session_unavailable'`; a pending link yields 409
`idempotency_conflict` with `state:'pending_approval'`. Link cancellation/expiry yields the
existing invalid-link result. Credential/public-context mismatches are not
accepted as idempotent retries.

The source device and, once created, recipient device must remain active for
all transitions. Claimed status uses original link expiry; approved/consumed
read-only status and already-committed receipt retries use the fixed transfer
deadline. Neither window authorizes a second initial session.

## Transfer resource

The same base path hosts `/{id}/history` POST/GET/DELETE, `/history/content`
GET and `/history/ack` POST. Ciphertext uses existing blob/quota/deletion
interfaces; handoff is bounded at 8 KiB, one immutable transfer per link,
seven-day deadline, ranged/ETag retries and durable import ACK. Only the
creator uploads; only the exact recipient's claim credential or device
session downloads/ACKs. No GET deletes data. The contract and test matrix
are specified in [K2-transfer-resource.md](K2-transfer-resource.md).
Migration 0039 implements that resource and durable quota-charged upload
intents through the guarded prepared-write capability.
