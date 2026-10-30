# K2 internal Rust primitives — 2026-10-26

Status: internal implementation slice only. K2 is not complete or reachable
from the app. No FFI, protocol-v3 routes, credential flow, native state
upgrade, snapshot importer or chat timeline integration is enabled here.

Files: `crypto/rust/src/history.rs`, its private module declaration in
`lib.rs`, and [the K2 design](../../docs/designs/K2-new-device-history.md).
The scoped dead-code allowance is deliberate while the module remains
unwired. Release gates and ABI v7 are unchanged; no dependency was added.

Implemented:

- Exact K0 `VHC1` kind-2 header with empty recovery encapsulation/file-key
  fields; 1 MiB AES-256-GCM chunks bound to the full header hash.
- Bundle-only payload framing: u64 big-endian length, payload, zero padding
  to 64 KiB; at most 64 MiB total padded frame, including length/padding.
- Checked sizes/counts, exact chunk lengths, canonical padding and no
  trailing bytes; opening requires typed expected account/source identity,
  snapshot counter, plaintext version, header/ciphertext digests and size.
- Fresh FK/nonce and X25519 transfer key from the existing OpenMLS provider.
  Existing zero-on-drop secret types hold key material and plaintext buffers.
- Bounded HPKE handoff with fixed secret-bound info and contextual AAD,
  credential Ed25519 signature, pinned source/recipient identities and
  optional recovery-public-key ID validation. Private transfer keys are not
  exported. This module does not implement recovery-key generation/opening.

Checks on Windows:

```
cargo +1.91.0-x86_64-pc-windows-msvc test --locked history::tests
# 9 passed
cargo +1.91.0-x86_64-pc-windows-msvc test --locked
# 38 unit + 2 integration passed; 2 measurement tests intentionally ignored
cargo +1.91.0-x86_64-pc-windows-msvc clippy --all-targets -- -D warnings
# passed
cargo +1.91.0-x86_64-pc-windows-msvc fmt
```

The header/hash vector was independently computed with Python stdlib
`struct.pack` and `hashlib.sha256`:

```
56484331020006616363745f3100076465765f6f6c6400000192cc091400000000000000000700000000000100000000000100000500000000
SHA256 = 7a91fb3a0bcdf84232d0a8f181bed8773782eda0f2752b803808be9e32358395
```

The nine tests cover empty/bucket/multi-chunk payloads, fresh key material,
header-vector round trip, overflow and invalid metadata, context/digest/
counter/version mismatches, authenticated noncanonical plaintext frames,
corruption/truncation/trailing data, same-sized chunk reordering, HPKE
recipient/link-secret/source-signature/context substitution, all truncated
handoff plaintext prefixes, and optional recovery-key identity mismatch.

The first strict clippy run reported a manual `is_multiple_of` pattern; it
was replaced and the final strict lint passes. Full repository scripts are
coordinated by the parent agent; the pre-existing Windows full-suite limits
are recorded separately in L0 evidence. Do not count this slice as a working
new-device history feature or as human review under G25.

Resumed verification on 2026-10-27: the full Rust suite (38 unit and 2
integration tests), fmt check and strict clippy all pass. The coordinator
independently reviewed the internal code and
reported no blocking findings; that approval covers this unwired primitive
slice only, not the proposed native-state migration, ABI or live transfer.

Subsequent native state/proof implementation is recorded separately in
[`K2-native-state.md`](K2-native-state.md); its newer counts do not replace
the historical primitive-slice check results above.
