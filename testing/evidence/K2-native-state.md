# K2 internal native state and v3 proof — 2026-10-27

Status: implemented internal Rust slice; not an end-to-end K2 feature.
Public FFI/header/ABI v7 remain unchanged. L0 protocol v2 remains supported;
the native sealed-state writer now emits format v3 and reads v2/v3. No new
dependency, release availability or Flutter/server implementation is added
by this slice.

Files: `crypto/rust/src/mls.rs`, `mls/state.rs`, new `mls/link_v3.rs`,
`mls/transfer.rs`, and small native-only state helpers in `history.rs`.
Design: [`K2-native-state-migration.md`](../../docs/designs/K2-native-state-migration.md).

## Implementation

- A bounded sorted map holds typed incoming/outgoing transfer contexts,
  immutable original link expiry, fixed approval/transfer deadline, native
  transfer private key, secret handoff key and optional source file material.
  Record parsing validates role/outer identity, closed status enums, exact
  bounds, transcript reconstruction, saved verification tags/SAS prefix,
  private/public HPKE pair consistency and conditional fields.
- The source/recipient retain the nonce and derived tag/SAS result after the
  scanned raw secret is erased. They do not try to derive other HKDF domains
  from the handoff key. Secret buffers use the existing zero-on-drop types,
  with capacities reserved before copying secrets to avoid Vec growth
  leaving old plaintext allocations behind.
- Exact incoming retries recover the same native key/context/public result
  before generating a new key. Exact source claim/material retries preserve
  status/deadlines and reject changed fields. Importing can reopen the same
  verified opaque handoff after restart without downgrading status; another
  randomized encapsulation is refused after the first verified digest.
- The post-checkpoint review additionally requires a durable source user
  intent before HTTP approval. Waiting records retain sealed recovery context
  for at most original link expiry plus seven days, with all normal expired
  operations blocked. A valid approval tag may activate that context late
  only within the original approval window and fixed transfer retention;
  the source must already hold its committed intent. This last delta is
  implemented in `mls/transfer.rs`; its first check attempt hit
  Windows virtual-memory exhaustion (OpenMLS metadata mmap, OS error 1455).
  Retrying with one compiler job passes all seven transfer tests, the full
  51-unit/2-integration Rust suite, fmt check and strict clippy.
- Cancel/expiry drops native secret wrappers and removes records from future
  serialization. Tests verify record removal and owning drop types without
  unsafe reads of freed memory pretending to prove allocator behavior.
- Native envelope v3 wraps the unchanged provider-record encoding plus typed
  transfers. It retains minimum-counter, identity, AEAD/header, record-count,
  duplicate-key and exact-length checks. Provider records are written in a
  canonical sorted order. A valid genuine v2 envelope restores with no
  transfer records and subsequently re-seals as v3.
- Protocol-v3 transcript/HKDF/HMAC and the domain-separated signed enrollment
  proof are internal helpers only. The signed bytes include the <=64-byte
  UTF-8 device name and all immutable credential hashes. No raw credential
  generation, HTTP flow or public transfer API is implemented here.

## Independent old-format fixture

`crypto/rust/tests/fixtures/state-v2/` was generated through the original v2
writer **before** changing the encoder. The archived generator asserts v2;
manifest hashes bind the resulting synthetic source/peer states, continuation
ciphertext and public key. All data is synthetic, with fixed test state keys.

The regression test restores the original v2 source, verifies the same
signing public key, decrypts a queued message from its peer, re-seals v3 and
exchanges new messages with the independently restored peer. This exercises
the live MLS group/provider state rather than checking only public labels.

The shared signed-proof vector is 481 bytes, independently assembled using
Python `struct.pack`/`hashlib`; SHA-256:
`70e1a994b2e4e2878cdab80c38c26012177780bd93b2cacaf73c1699389d6f78`.
The server worker received the same complete inputs independently.

## Verification

Final completed checks:

```
cargo +1.91.0-x86_64-pc-windows-msvc test --locked -j 1
# 51 unit + 2 integration passed, 2 measurement tests intentionally ignored
cargo +1.91.0-x86_64-pc-windows-msvc clippy --all-targets -j 1 -- -D warnings
# passed; cargo fmt --check also passed
```

Narrow tests include genuine v2 migration, rollback/identity/corruption,
every v3 transcript/proof field, malformed native record prefixes/counts/
sizes/enums/options, inconsistent transfer private key, duplicate records,
native restart at claim/approval/importing, exact retry after the original
claim window, and cleanup/deadline rules. An authenticated-v3-wrapper
test also rejects wrong wrapper magic, oversized sublengths, trailing bytes
and duplicate provider records even with a valid outer AEAD.

The first attempt to run full checks after allocation hardening was rejected
by automatic approval review because the account usage limit prevented that
review; the action was not executed. After the user resumed work following
the retry window, the checks above ran successfully. This was a review
availability failure, not a safety finding; it was not bypassed.

Root independent review found two retry gaps and one importing crash gap;
the fixes and regression tests above address them. Final review/verification
of this complete native delta still belongs to the coordinator. Whole-repo
and Linux snapshot checks remain coordinated there. K2 app integration,
server transfer resource, ABI8/bindings, history importer and timeline remain
separate work; production gate G25 remains closed.
