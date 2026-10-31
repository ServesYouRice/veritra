# Genuine format-3 native state fixtures (D70 S1)

Generated through the format-3 `MlsDevice::seal_state` on 2026-10-31, on
top of commit 5102363, before the D70 S1 storage split (partitioned
provider). `generator-v3.rs` is the archived generator; it ran once as an
ignored in-crate test (the K2 transfer API is crate-private) and asserts
the envelope version is 3. Do not regenerate these files with a later
encoder: the regression tests need an independent old-format input.

All identities, messages and state keys are synthetic. `manifest.json`
records the fixed keys, counters and SHA-256 of each file. No real device,
account, credential or user message appears here.

`source.bin` (`acct_fixture3`/`dev_src`, key `0x73` × 32, counter 51) holds:

- `conv_alpha`: created by the source, the peer joined, one message each
  way, and an unmerged staged self-update (`staged-update.bin` is its
  commit);
- `conv_beta`: created by the peer, joined by the source from a key
  package;
- `conv_gamma`: joined, then the source applied its own removal (inactive);
- two unclaimed key packages (`unclaimed-1.bin`, `unclaimed-2.bin`);
- two K2 transfers: `link_out` (outgoing, approved) and `link_in`
  (incoming, waiting for approval, with its transfer key pair).

`peer.bin` (`acct_peer3`/`dev_peer`, key `0x74` × 32, counter 52) is the
peer after it sent `peer-next.bin` in `conv_beta`.
