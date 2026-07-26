# I24 — Build signed apps and run real-device checks

Goal: produce reproducible Android/iOS release candidates and verify core flows on real devices.

Read:

- mobile platform/release configuration
- CI/release workflows and SBOM/license scripts
- completed I10–I23 handoffs

Do:

1. Build Android and iOS release candidates with pinned native crypto and compatibility metadata.
2. Generate dependency notices, SPDX SBOM, checksums, provenance, and signatures.
3. On two real devices, test setup, invite, DM/group, link, offline catch-up, actions, revocation, restart, and restore if in scope.
4. Run TalkBack, VoiceOver, large-text, background, and network-loss checks.
5. Record failures as small cards; do not waive them silently.

Done when: signed artifacts install and the release matrix passes on supported Android/iOS versions.

External signing/publication requires user approval. Never commit credentials or signing material.
