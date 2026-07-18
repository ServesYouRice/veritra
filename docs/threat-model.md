# Threat Model

## Assets

- Message plaintext and attachment plaintext.
- User private keys, device secrets, backup recovery material.
- Session tokens and setup secrets.
- Social graph, membership, delivery, and call metadata.
- Encrypted backups and encrypted attachment blobs.

## Adversaries

- Malicious or curious server admin.
- Compromised server or database theft.
- Lost or stolen user device.
- Stolen encrypted backup.
- Malicious invited user.
- Spam or abuse actor.
- Push notification provider observing metadata.
- Network observer in non-HTTPS or LAN deployments.

## Required Protections

- Server stores ciphertext-only message bodies and attachment contents.
- Server logs never include request bodies, message contents, tokens, passwords, private keys, or recovery secrets.
- Admin tools cannot silently decrypt private content.
- Invite-only registration is default.
- A short-lived in-memory rate limiter uses a salted hash of the remote address and does not persist IP addresses.
- Password fallback uses strong hashing; passkeys remain a documented future path.
- Setup owner creation requires a custom setup header so browser cross-site form posts cannot silently complete setup.
- Mobile private keys and local storage must use platform secure storage or encrypted stores before production.
- Push payloads are generic availability signals.
- Search over message content is local-only on clients.
- Backups are encrypted client-side before upload.

## Metadata Leakage

The server necessarily sees account IDs, device IDs, membership, delivery timing, conversation IDs, attachment sizes, and call lifecycle timing. Call SDP/ICE signaling content must use the strict encrypted-envelope schema and is opaque to the server. Future work should reduce and document the remaining metadata, but v1 must avoid pretending metadata is hidden from the server.

## Explicit Non-Goals for MVP

- Anonymous routing.
- Federation.
- Server-side full-text message search.
- Admin recovery of plaintext.
- Production-grade call E2EE until media architecture is implemented and audited.
