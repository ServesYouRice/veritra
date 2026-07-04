# TODO

- Integrate OpenMLS through Rust bindings and Flutter FFI.
- Design key-distribution APIs for conversation/member device key packages.
- Add client decrypt/render support after production key storage exists.
- Implement production encrypted local mobile storage for key material and the message cache. (Session secrets already use `flutter_secure_storage`; private keys and decrypted message storage are the remaining gap.)
- Add QR scanning/rendering and production key-continuity checks to the current manual device-link UX.
- Add encrypted backup creation and restore UX on mobile.
- Add ciphertext list/download endpoints for attachments and backups.
- Add APNs/FCM/UnifiedPush provider implementations.
- Add client-side local message search.
- Add attachment upload from Flutter with client-side encryption.
- Add WebRTC media or LiveKit integration after call E2EE review.
- Define and implement the account-deletion retention/scrubbing policy.
- Decide whether `devices.last_seen_at` should be written for lost-device review UX.
- Add PostgreSQL and S3 adapters only when needed.
- Run full dependency license scan before release.
