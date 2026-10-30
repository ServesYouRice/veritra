# L0: secret-authenticated device linking

The old device generates a fresh 16-byte secret with the platform CSPRNG.
The QR and manual code carry only its 26-character unpadded RFC 4648 base32
encoding. The server receives only the lowercase hex SHA-256 of
`veritra-link-locator-v2 || secret`. It cannot recover the secret from this
locator. Manual input accepts spaces and hyphens for grouping.

Protocol `veritra-device-link-v2` preserves the length-prefixed v1 transcript
fields, with new context fields: domain, version, canonical client-configured
server origin, link ID, account, nonce, old device/key, new device/key.
The transcript hash is public. HKDF-SHA256 uses an all-zero 32-byte salt,
the secret as IKM, and separate info labels `veritra-link-sas-v2`,
`veritra-link-claim-v2`, `veritra-link-approval-v2`. Each 32-byte output keys
HMAC-SHA256 over the full transcript. The SAS is the first four MAC bytes
as a big-endian integer modulo 100000000, padded to eight digits.

The new device sends only the claim MAC. The old device checks it before
offering approval, and requires the user to type the new device's SAS.
Only approval sends the approval MAC. The new device checks that MAC and
the transcript and reserved account/device IDs before saving a session.
Direction-separated MACs prevent reflecting a claim as an approval.
Absent tags, v1, changed context, and malformed codes fail closed.

ABI v7 extends the device-link derivation with the origin, link ID and 16-byte secret and returns
100 bytes: transcript hash, claim MAC, approval MAC, then four SAS MAC bytes.
A handle-free locator helper hashes the secret without exposing it to HTTP.
The secret lives in memory for the link only; it is never persisted or logged.
Server migration 0037 stores the two opaque tags and retires unfinished v1
links. Enrollment, claim, approval and consumption retain their expiry and
single-use checks. Existing device sessions and MLS state are unchanged.

K2 will version its transfer-key transcript separately. L0 authenticates a
link; the signed approved-device list (L1) is still required to prevent a
malicious server adding devices outside this flow. Production gates stay shut.
