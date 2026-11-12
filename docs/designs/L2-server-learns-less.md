# L2: server learns less

**Status: proposed (2026-11-07). L2-1 and L2-5 built in round 7; L2-3 designed 2026-11-12 (D122) and being built behind a server switch (see its section).** A design only, against `main`
(crypto ABI 13, server migration 0049, local schema 20). Steps L2-3 (sealed
sender) and L2-5 (own-device alert) touch security, MLS and credential
decisions, so each needs an independent review (AGENTS.md) and the owner's
answers at the end before it is built. The release gates G24 and G25 do not
change.

Naming: "L1 (approved-device list)" below is the design in
[`L1-approved-device-list.md`](L1-approved-device-list.md), not the
"L1 More features" row in STATE.md's Later table.

## Summary

Message content is already end-to-end encrypted. L2 shrinks what the server
learns *around* the content: sizes, addresses, times, who sent what, and
whether the code it runs is the code in this repository.

| Step | What the user gets | Counters |
|---|---|---|
| L2-1 Padding | Commits, Welcomes, key packages and other uploads leave the phone in fixed size buckets, as messages and files already do | +1 ABI, no migration, no schema |
| L2-2 Fewer logs | The shipped proxies stop writing client addresses; stored times are coarse where nothing needs them exact | +1 migration, no ABI, no schema |
| L2-3 Sealed sender | For ordinary messages, the server stores no sender device | +1 ABI, +1 migration, +1 schema, new dependency (owner first) |
| L2-4 Reproducible server | Anyone can rebuild the server image and get the same digest the release published | none |
| L2-5 Own-device alert (D94) | When your phone finds a device you never approved in a chat, the other members are told too | none (a W7 type registry entry) |

Numbers are the next free ones when each step lands; nothing here reserves
one. Other packages (L1, C7, #138) are claiming numbers in parallel.

## Where things stand

- **Payload padding exists.** `VAP1` pads to 256-byte buckets with random
  fill, and receivers refuse a length that is not a multiple of 256
  (`mobile/lib/crypto/app_payload.dart:10`, `:244-246`). Attachment sizes are
  padded to Signal-style buckets (manifest v2, D60-D63).
- **Not padded:** MLS commits, Welcomes, key packages, the D28 commit
  bundle, `history_sync`, K2 transfer blobs, and send timing (a message
  leaves the moment it is typed).
- **The app stores no client address.** No migration has an IP column; IPs
  live in memory only, for rate limits and setup checks
  (`server/internal/httpapi/client_identity.go`); httpapi logs route
  patterns, not addresses.
- **The proxy does log addresses.** The shipped Caddy profile
  (`deploy/caddy/Caddyfile`) deletes the URI and credential headers from its
  access and error logs but keeps `remote_ip`, timestamps, user agent and
  sizes. Nothing in `deploy/kubernetes` turns on a Traefik access log; the
  private `infra` repo decides that, so L2-2 documents keeping it off.
- **Times are stored exactly:** `devices.last_seen_at`
  (`identity_store.go:370`), every `created_at`, and W5's delivery and read
  cursors (D47).
- **The server knows every sender.** `envelopes` and `mls_messages` carry
  `sender_device_id` (`0001_init.sql:91`, `0021_mls_messages.sql:5`), and it
  is used for: `UNIQUE(sender_device_id, idempotency_key)` dedupe; D25 sender
  binding (`pm_crypto_group_decrypt` takes the expected sender account and
  device and returns `PM_CRYPTO_SENDER_MISMATCH`); C2 `posting_restricted`;
  C6 franking (its design says attribution relies on an honest server row);
  hiding blocked senders' events; per-device limits; and D28 commits.
- **Server builds are close to reproducible.** `server/Dockerfile` pins the
  Go image by digest and builds with `-trimpath -buildvcs=false -buildid=`
  into `scratch`; `release.yml` adds an SBOM and provenance attestation. No
  script rebuilds a release and compares digests.

## Threats

The adversary is the server operator, or someone who has taken the host.

| What they learn today | With L2 | Left |
|---|---|---|
| Exact sizes of commits and Welcomes (roughly how many members are added) | Bucket sizes only (L2-1) | Counts of messages per conversation |
| When each person types, from send times | Unchanged by default; owner question 3 adds optional send jitter | Timing is visible to anyone on the network path |
| Client IP per request, from the proxy log | Not written by shipped configs (L2-2) | The live connection still shows the IP in memory; an operator can turn logs back on. Tor or a VPN is the user's tool |
| Exact last-seen time of each device | Day-level (L2-2) | The live WebSocket shows presence while connected |
| Who sent each message | For application messages, not stored (L2-3) | Who is online when a message arrives; commits stay identified |
| Whether the running server is the published code | Anyone can check the published image (L2-4) | Not whether the operator *runs* that image: that is L3, and even L3 is not operator-proof |
| A device the server slipped into a chat, unseen by peers who trust a stale list | Peers hear it from the account's own device (L2-5) | First contact; a server that drops the alert message. Key transparency, owner question 5 |

## Steps

### L2-1 Padding (Opus review)

- One padding rule in Rust for every blob the app uploads that is not
  already a `VAP1` payload or an attachment: commit bundle, Welcome, key
  package, `history_sync`, K2 transfer chunks. Buckets: 256-byte multiples
  up to 4 KiB, then powers of two up to the route's cap (`mls_handlers.go`
  reads at most 6 MiB and 12 MiB).
- The padding goes inside the encrypted or signed bytes and only the
  receiver strips it; an outer pad the server strips would show it the real
  length. Application messages use MLS `PrivateMessage` padding.
- `crypto/rust` sets no wire-format policy, so commits most likely go out as
  OpenMLS's default `PublicMessage` (confidence 65%, to confirm first).
  Then commits need either a pure-ciphertext policy (its own crypto change,
  and the server can no longer read D28 roster changes from the commit) or a
  pad inside the D28 bundle. Default: pad inside the bundle.
- Key packages carry a padding extension; the server's structural check
  (`server/internal/mlswire`) must accept it, which is a server change.
- `VAP1` stays on 256-byte multiples. Larger buckets for payloads would need
  a `VAP2`, which older apps refuse, so it is out of scope.
- **Counters: +1 ABI** (padding policy passed to commit and Welcome creation,
  and a strip on receive). Older libraries refuse padded blobs: every client
  must move together, like the ABI 9 rule in STATE.md's release gates.
- `docs/crypto.md` change-log entry.

### L2-2 Fewer address and time logs (Sonnet)

- Caddy: add `request>remote_ip delete`, `request>client_ip delete`,
  `request>remote_port delete` and `request>headers>User-Agent delete` to both
  `log` blocks. Traefik: access log off in the shipped base, or the same
  fields dropped. `docs/operations.md` says what an operator turns back on,
  and that doing so is their choice.
- Coarsen stored times that nothing orders by:
  `devices.last_seen_at` to the UTC day. Each other timestamp is checked
  against its readers first (retention pruning, D47 cursors, K0 7-day wait,
  session idle/absolute limits in D34 all need real times); only columns no
  reader needs exact are coarsened. Ordering always comes from event ids.
- **Counters: +1 migration** (rounds existing `last_seen_at` values).
  No ABI, no schema.

### L2-3 Sealed sender for application messages (Opus designs)

**Design delta (2026-11-12, D122).** The owner chose VOPRF credentials
(option B). The design that replaces the "delivery token" bullet below is in
[`docs/crypto.md`, "Sealed sender with VOPRF tokens"](../crypto.md#sealed-sender-with-voprf-tokens-d122-crypto-abi-26-design-2026-11-12):
RFC 9497 POPRF over ristretto255-SHA512 (`voprf` 0.5.0 in Rust, `circl`
v1.6.5 in Go), `info` binding conversation, UTC day and a per-conversation
generation that a removal raises; issuance per account, conversation and
day; redemption on an unauthenticated route with a spent-nonce table;
sealed envelopes in their own table with no sender column. Changes against
the text below:

- **C6 is solved, not refused.** A sealed, franked payload carries the
  sender's Ed25519 signature over the franking commitment inside the
  ciphertext (`frank.s`); receivers check it against the sender's leaf and
  reporters reveal it, so a sealed message stays reportable and framing
  fails. Cost: a revealed report is a transferable proof (owner question).
- **Scope.** DMs and plain groups only. Admins-only groups, any
  conversation with a C5 timeout, communities and channels (C0, C5 slow
  mode, C7) and messages with attachments stay identified.
- **Storage.** No nullable column on `message_envelopes` (an SQLite rebuild
  of a table that many others reference). A separate table and sync event
  type; the readers that must know it are listed in the crypto section.
- **Leaks** (IP, timing, typing, issuance counts, first-contact key
  tagging) are listed there plainly.

Counters: crypto ABI 26, local schema 43, migrations 0090-0091.

Scope: application messages only. Commits, Welcomes, key packages, reports
and every admin or membership route stay identified.

- **Delivery token instead of a device.** For each conversation, the server
  issues members an anonymous credential that proves "a current member of
  conversation X" without naming the device (Signal's group send
  endorsements are the model). The send route accepts that token on a
  separate, unauthenticated connection; the device's normal session is
  never used to send.
- **Sender inside the ciphertext.** MLS already encrypts the sender leaf in
  `PrivateMessage` sender data. Receivers read the sender from MLS instead
  of from the server row. That changes `pm_crypto_group_decrypt`: it must
  *return* the sender pair rather than check one passed in, and D25's
  binding moves from "envelope says, MLS confirms" to "MLS says". A
  `docs/crypto.md` D25 entry records it.
- **What breaks, and the fix for each:**

  | Server use of `sender_device_id` | With sealed sender |
  |---|---|
  | Dedupe `UNIQUE(sender_device_id, idempotency_key)` | Key on `(conversation_id, random 128-bit idempotency key)` |
  | D25 sender binding | From MLS sender data (ABI change above) |
  | C2 `posting_restricted` | Server cannot refuse; members' apps drop disallowed posts (C2's client half). In admins-only conversations the app sends identified |
  | C6 franking attribution | **Unsolved.** The sender writes `sender_device_id` into the franking HMAC itself, so member M could send a sealed message naming victim S (honest receivers drop it), then report it and frame S. Today the authenticated server row stops that. Sealed messages are therefore **not reportable**; conversations with reporting on send identified. Fixing it needs asymmetric franking: new crypto, its own package |
  | The sender's own copy comes back in fan-out | The server cannot leave the sender out, and OpenMLS cannot decrypt its own `PrivateMessage`, so under I33 sync would stop. The sending device recognises its own message by the random idempotency key held in its outbox and skips it |
  | Blocked senders hidden by the server | Hidden by the receiving app only |
  | Other readers of the column (0044 prune check, B8 message requests, revocation store, account export) | Each is listed and checked in the L2-3 PR before the column becomes nullable |
  | Per-device send limits | Per-token limits; tokens are rationed per member per epoch |
  | D28 commits | Unchanged: commits stay identified |

- **Counters: +1 ABI, +1 migration** (nullable sender columns, new dedupe
  index, token issuance state), **+1 local schema** (sender taken from MLS,
  stored with the message). A zero-knowledge credential crate is a **new
  dependency: owner first**, with licence review and
  `THIRD_PARTY_NOTICES.md`.

### L2-4 Reproducible, signed server builds (Sonnet)

- `scripts/verify-server-build.sh <tag>`: checks out the tag, builds with
  the pinned Go digest and `SOURCE_DATE_EPOCH` from the commit, and compares
  the per-platform server binary SHA-256 and image manifest digest with the
  release. Not the multi-arch index: its provenance (`mode=max`) and SBOM
  attestations embed per-run data, so it differs every build.
- Pin the remaining unpinned inputs it finds (Go module proxy via
  `go.sum`, BuildKit version).
- The release keeps GitHub provenance; adding a keyless signature
  (`cosign`) is owner question 4.
- L3 builds its expected VM measurement from this verified binary; the
  image digest is an input to that measurement, not the measurement itself.
- **Counters: none.**

### L2-5 Own-device alert (deferred from L1 by D94)

Copied from L1-4 so the two designs agree:

- A hidden W7 type `device_list_alert {account_id, head_version, list_id}`.
- A device sends it in a group where its own-account audit found an
  unapproved leaf of its own account.
- Receivers refresh that account's list; a different list identity or a fork
  becomes `conflict` (L1 states), and the chat shows the L1 warning.
- Sent identified (it is about the sender's own account), never sealed.
- **Counters: none** (a W7 type registry entry). Needs L1-3 first.

## Test plan

- **L2-1:** Rust vectors for every bucket edge (0, 255, 256, 4096, 4097,
  cap); a padded blob round-trips; a truncated or over-cap pad is refused;
  an older library refuses a padded blob (fail closed). Demo e2e: server-side
  log of upload sizes shows only bucket values.
- **L2-2:** a Caddy config test (`caddy adapt` + a request) shows no IP or
  user agent in either log; Go test that `last_seen_at` is written at day
  precision and the migration rounds old rows; every existing retention,
  D34 and K0 wait test still passes.
- **L2-3:** Go tests: a token from a removed member is refused; a token is
  not linkable to the device in stored rows; dedupe works without a sender;
  identified routes still refuse a token. Rust/Dart: sender taken from MLS
  matches the leaf; a forged sender in the outer frame has no effect.
  Grep test: no sealed send stores a device id. The sender gets its own
  sealed message back and skips it without stopping sync. A report of a
  sealed message is refused. Demo e2e: two clients chat
  with sealed sender on; C2 and C6 tests updated to their new paths.
- **L2-4:** CI job rebuilds the last tag and compares digests; a changed
  byte in the tree changes the digest.
- **L2-5:** the L1 test-only hook inserts an unlisted device; the other
  member's app shows the warning after the alert, and a forged alert from a
  different account is ignored.
- All steps: `scripts/test`, `scripts/lint`; `scripts/release-readiness.sh`
  fails for the same reasons as before.

## Open questions for the owner

1. **Sealed sender at all?** It removes C2's server refusal and cannot be
   reported safely (C6). **Default: yes, application messages only, built
   after C2 and C6 land; admins-only conversations and conversations with
   reporting on send identified**, so sealed messages are never reportable.
2. **New dependency for anonymous credentials.** **Default: allow one
   reviewed crate** (to be named in the L2-3 PR with its licence), or skip
   L2-3.
3. **Send-time jitter** (random 0-2 s delay to blur typing times).
   **Default: off**; it makes chat feel slower and only helps against the
   server.
4. **Sign server images with cosign** on top of GitHub provenance.
   **Default: no**; provenance plus the digest-compare script is enough
   and adds no dependency.
5. **Key transparency** (the gap L1 leaves: first contact and withheld
   lists). **Default: a separate later package**, not part of L2.
6. **Proxy logs off by default** even for small self-hosters who want them
   for abuse handling. **Default: yes, off**, with a documented line to
   turn them on.
