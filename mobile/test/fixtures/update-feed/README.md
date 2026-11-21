A signed test vector for the Windows update feed (scripts/update-feed.py).

- `update.json` and `update.json.sig`: a feed and its detached Ed25519
  signature (64 raw bytes over `veritra-update-feed-v1` followed by the exact
  bytes of `update.json`).
- `public-key.hex`: the matching public key (32 bytes, 64 hex characters).

The key pair was generated for this vector alone and its private half was
thrown away. It is not the update key and nothing trusts it. The feed
expires 2027-02-19 (exactly the 90-day maximum); tests read it as data and
pass their own clock. It is the known-answer vector of
`pm_crypto_update_feed_verify` (crypto ABI 27): Rust
`crypto/rust/src/update_feed_tests.rs` and Dart
`mobile/test/update_feed_native_test.dart` check it.
