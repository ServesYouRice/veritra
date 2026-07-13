# Production cryptography contract

Status: required design contract; implementation is not production-ready.

## Protocol choice

- Messaging groups use MLS 1.0 (RFC 9420) through a reviewed OpenMLS release.
- Each linked device is a distinct MLS client with its own credential, signature key, HPKE key package, and secure local state.
- The server is an untrusted delivery service. It stores public key packages, MLS handshake/application ciphertext, opaque attachment ciphertext, and routing metadata only.
- No compatibility fallback may send plaintext or use the test protocol markers.

## Identity and device binding

- An account ID is not a cryptographic identity by itself.
- Device credentials bind the account ID, device ID, protocol version, and signature public key.
- Initial-device creation and linked-device approval must sign a server nonce and the complete public device credential.
- Existing devices show a short authentication string derived from both credentials before approval.
- Removing a device requires an MLS remove proposal/commit in every affected group. Server revocation alone does not claim cryptographic removal.

## Conversation lifecycle

- A DM is an MLS group containing the active devices of exactly two accounts.
- Groups and channels are MLS groups whose roster is derived from authorized conversation membership.
- The creator commits the initial roster before any application message can be sent.
- Membership changes become effective only after a valid MLS commit is processed locally; the server membership row is authorization/routing state, not proof of cryptographic membership.
- Clients reject application messages from epochs they cannot authenticate and request missing handshake messages without skipping epoch validation.

## Message envelope

- `crypto_protocol` is a versioned allowlisted identifier, initially `mls10-openmls-v1`.
- `ciphertext` contains an MLS application message only.
- `crypto_metadata` may contain protocol version, group identifier, epoch, content type, padding class, and client-generated opaque references. It must not contain plaintext previews, sender names, filenames, or keys.
- Reply/thread relationships and attachment references are authenticated inside the encrypted application payload; server-visible IDs are routing hints and must match the authenticated payload after decryption.
- Clients pad application payloads into documented size classes before MLS encryption to reduce length leakage.

## Key packages and rotation

- Key packages are single-use, signed, expire within a bounded interval, and are deleted from the server when claimed.
- Clients maintain a small replenished pool per device and reject reused, expired, unsupported-ciphersuite, or uncredentialed packages.
- Signature and HPKE keys are generated inside platform secure storage where supported; exportable key bytes must be wrapped immediately by a non-exportable platform key.
- Rotation creates a new credential/key-package generation and commits updates to every active group.

## Local state and recovery

- MLS group state, private keys, decrypted cache, search index, and pending plaintext are encrypted at rest with an account/device key protected by Android Keystore or iOS Keychain/Secure Enclave facilities.
- The existing encrypted outbox stores only already-encrypted envelopes.
- Backups are encrypted client-side with a recovery key never sent to the server. Backup manifests authenticate account/device scope, format version, KDF parameters, object hashes, and rollback counters.
- Recovery restores keys only when the user supplies the recovery secret or an already-verified device transfers them. Password reset cannot recover message keys.

## Failure and rollback rules

- Missing native bindings, unsupported versions/ciphersuites, invalid credentials, signature failures, epoch gaps, rollback detection, or secure-storage failures all fail closed.
- A client never advances a durable MLS epoch or sync cursor until the resulting encrypted local state is committed atomically.
- Server retries use stable idempotency keys. Duplicate delivery must not cause a second MLS state transition.
- Deleted/revoked devices cannot fetch new key packages or handshake messages, but clients still perform cryptographic roster removal.

## Required review evidence

- Exact OpenMLS version, feature set, dependency licenses, and platform bindings.
- Interoperability vectors for create/add/remove/update/application/exporter flows.
- Multi-device and offline epoch convergence vectors.
- Secure-storage, backup rollback, corrupt-state, and device-revocation analysis.
- Independent review of protocol integration and mobile key handling before `PM_CRYPTO_UNAVAILABLE` is removed.
