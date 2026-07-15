# TODO

- Integrate OpenMLS through Rust bindings and Flutter FFI.
- Implement and independently review the requirements in `crypto-protocol.md`.
- Add client decrypt/render support after production key storage exists.
- Store future MLS private keys through the platform keystore integration. The current bounded ciphertext cache, cursor, and encrypted outbox already use platform encrypted storage.
- Complete production cryptographic key-continuity checks for the implemented QR device-link flow.
- Add encrypted backup creation and restore UX on mobile.
- Add optional APNs/FCM adapters only after provider credential and privacy review.
- Add client-side local message search.
- Add attachment upload from Flutter with client-side encryption.
- Add WebRTC media or LiveKit integration after call E2EE review.
- Decide whether `devices.last_seen_at` should be written for lost-device review UX.
- Add PostgreSQL and S3 adapters only when needed.
- Complete the release dependency/license review and preserve the generated SPDX SBOM with every release.
