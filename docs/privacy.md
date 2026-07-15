# Privacy

Veritra defaults to:

- no telemetry
- no analytics
- invite-only registration
- no phone numbers
- optional email only
- ciphertext-only server message storage
- encrypted attachment storage
- generic push notifications
- client-side message search only

Operational logs are local to the instance and intentionally sparse. They must not include request bodies, secrets, tokens, private keys, plaintext messages, or plaintext attachments.

## Account Deletion

Account deletion immediately:

- active sessions are deleted
- devices are revoked and their names/public key packages are scrubbed
- username, email, and password credentials are scrubbed
- memberships, reactions, read receipts, device links, and push endpoints are removed
- encrypted attachment and backup rows are removed and their blob files are deleted

Pseudonymous account/device IDs and already-sent ciphertext envelopes remain where required to preserve other participants' conversation history and audit integrity. Server backups made before deletion retain their historical snapshot until the operator's documented backup-retention period expires. The server cannot erase plaintext copies or exported backups held by other participants because it never possesses those plaintexts or devices.
