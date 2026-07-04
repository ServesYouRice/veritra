# Privacy

Private Messenger defaults to:

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

Current account deletion is a soft-delete workflow:

- active sessions are deleted
- devices are revoked
- the account is marked deleted

The current implementation does not yet scrub usernames, optional email values, device key-package metadata, encrypted message envelopes, encrypted attachment rows/blobs, encrypted backup rows/blobs, or push subscription endpoints. Define and implement the final retention/scrubbing policy before production release.
