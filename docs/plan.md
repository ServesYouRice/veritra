# Product Status

Date: 2026-07-13

## Implemented foundation

- Android and iOS Flutter projects with secure platform defaults.
- Transactional ciphertext messaging, membership events, reactions, retention, attachment references, and pruned-cursor recovery.
- Durable bounded mobile ciphertext cache and encrypted outbox in platform secure storage.
- Community/channel read models, invite/device management, recent authentication, password rotation, and offline owner recovery.
- Authorized attachment/backup lifecycle, quotas, full instance backup manifests, staged restore, readiness checks, and bounded cleanup.
- Realtime expiry, ping/pong, connection budgets, graceful drain, and privacy-safe management metrics.
- Pinned CI actions/toolchains/images plus checksummed SPDX/provenance release automation.

## Hard release blockers

- Production MLS/OpenMLS key lifecycle, encryption/decryption, secure private-key storage, verification, rotation, and recovery are not implemented. The client fails closed and `scripts/release-readiness.sh` prevents publishing a production release.
- A privacy-reviewed optional push delivery adapter and mobile registration/background-wake flow are not implemented.

## Deferred product work

- Client encrypted-backup creation/restore UX, encrypted attachments, and local plaintext search depend on production crypto.
- WebRTC/LiveKit media depends on a separate call-E2EE and dependency review.
- Broader application localization can be added when a second supported language is selected; current UI support is explicitly English with locale-aware dates/times and screen-reader semantics.
- The modular monolith can be split into narrower application services incrementally after the security transaction boundaries stabilize.

See [`audits-codex/status.md`](../audits-codex/status.md) for finding-by-finding remediation status.
