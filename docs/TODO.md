# TODO

- Integrate OpenMLS through Rust bindings and Flutter FFI.
- Design key-distribution APIs for conversation/member device key packages.
- Add client decrypt/render support after production key storage exists.
- Store future MLS private keys through the platform keystore integration. The current bounded ciphertext cache, cursor, and encrypted outbox already use platform encrypted storage.
- Add QR scanning/rendering and production key-continuity checks to the current manual device-link UX.
- Add encrypted backup creation and restore UX on mobile.
- Add APNs/FCM/UnifiedPush provider implementations.
- Add client-side local message search.
- Add attachment upload from Flutter with client-side encryption.
- Add WebRTC media or LiveKit integration after call E2EE review.
- Decide whether `devices.last_seen_at` should be written for lost-device review UX.
- Add PostgreSQL and S3 adapters only when needed.
- Complete the release dependency/license review and preserve the generated SPDX SBOM with every release.
