# Genuine pre-K2 native state fixtures

Generated through the existing format-v2 `MlsDevice::seal_state` on
2026-10-27, before implementing the v3 state writer/reader. The archived
`generator-v2.rs` asserts the envelope version is 2, so it intentionally
cannot silently regenerate these fixtures through the new v3 writer.

All identities, messages and state keys here are synthetic tests. The
manifest records the fixed test keys/counters and SHA-256 of each file.
No real device, account, credential or user message appears here.

The source and peer establish a real MLS group and exchange a message.
`source.bin` captures the source before the peer sends `peer-next.bin`.
`peer.bin` captures the peer after sending it. The migration test restores
the old source, decrypts that continuation, re-seals v3, and exchanges new
messages with the independently restored old peer. This verifies live group
and sender state, not merely preservation of an exported public key.

To reproduce, use the archived generator with the old v2 implementation in
an isolated checkout. Do not rewrite these files with the current encoder;
the regression test's purpose is to keep independent old-format inputs.
