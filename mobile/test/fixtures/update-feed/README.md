A signed test vector for the Windows update feed (scripts/update-feed.py).

- `update.json` and `update.json.sig`: a feed and its detached Ed25519
  signature (64 raw bytes over `veritra-update-feed-v1` followed by the exact
  bytes of `update.json`).
- `public-key.hex`: the matching public key (32 bytes, 64 hex characters).

The key pair was generated for this vector alone and its private half was
thrown away. It is not the update key and nothing trusts it. The feed
expires 2027-02-19; tests read it as data and do not depend on the clock. It is the known-answer
vector for the Ed25519 verification the app still needs
(docs/release-engineering.md, "Update channel").
