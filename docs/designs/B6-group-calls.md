# B6: group calls and voice rooms

**Status: S2 to S6 built as a demo-gated slice (2026-11-11), see "Build status"; S1, S7 and the media transport are not. The owner accepted every default below (D106).** Revision 2 (2026-11-07). Revision 1
had one independent review (key schedule, frame encryption, threats); its
five blocking points are fixed here. Needs the independent crypto review
before S2 lands.

- **Package:** B6 in the `STATE.md` build plan (route "Opus designs").
- **Done when:** "Encrypted voice rooms and screen share modelled on
  Discord's DAVE: MLS keys, SFrame frames, a forwarding server that cannot
  read them."
- **Owner approval:** one new server-side component (the SFU, O1) and
  possibly one Flutter client package for it. Neither is covered by D89.
- **Counters:** crypto ABI 22 (S2, used), server migration 0080 (S3, used), no local
  schema change. No local schema change
  (call state lives in memory only). No W7 payload type.

## Summary

- **One short-lived MLS group per call** (the DAVE model). Its members are
  the devices in the room right now, not every member of the conversation.
  Every join and every leave is a commit, so a new epoch and new media keys.
  Someone who joins cannot hear what was said before; someone who leaves
  cannot hear what is said after.
- **Only devices already in the parent group may join.** Participants'
  apps check that a joining device's credential and signature key match a
  leaf of the parent conversation's (or channel's) MLS group. The server
  cannot add a stranger.
- **Media keys come from the MLS exporter, per epoch**, then one key per
  sender and stream. Frames are encrypted end to end on top of the normal
  hop-by-hop DTLS-SRTP.
- **A selective forwarding unit (SFU) forwards encrypted frames.** It reads
  RTP headers to route and pick quality layers, never the media.
- **B5 (one-to-one) stays as it is:** peer to peer through TURN. B6 is for
  three or more people and for community voice channels.

## What exists today

- `server/internal/webrtc/webrtc.go`: a `SignalingService` interface
  (`CreateCall`, `SendSignal`).
- `call_sessions` table (migrations 0001, 0008, 0028) and
  `content_store.go`: **DM only**. A call needs `kind == "dm"`, exactly two
  members and an `invited_account_id`; states `ringing`, `active`,
  `rejected`, `missed`, `ended`, with a version check on each move.
- `call_sync_handlers.go`: `GET /api/v1/calls/config` (TURN URLs and
  short-lived HMAC credentials) and `POST /api/v1/calls/{id}/state`. Call
  metadata is an MLS ciphertext envelope of at most 48 KiB, with five fixed
  fields.
- `mobile/lib/calls/call_service.dart`: one `RTCPeerConnection` per call,
  relay-only ICE (D56) with a candidate filter, signals encrypted in the
  DM's MLS group.
- coturn, configured by `PRIVATE_MESSENGER_TURN_URLS` and the shared
  secret (`docs/operations.md`). The server never connects to TURN.
- `flutter_webrtc` 1.6.3 ships a **frame cryptor** (`FrameCryptor`,
  `KeyProvider`: AES-GCM, HKDF or PBKDF2 key derivation, a key ring, per
  participant keys). Its native code is present for Android, iOS, macOS,
  and, through `common/cpp`, Windows and Linux. *Confidence it works at run
  time on Windows and Linux: about 60%; S1 checks it.*

A voice room you can drop into at any time does not fit `call_sessions`
(two parties, ringing). B6 adds rooms beside it rather than bending it.

## Key schedule

### The call group

- The first device to join a room creates an MLS group with a fresh random
  32-byte group id and the same cipher suite as every other group
  (`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`). The group context binds
  `call_id` and the parent `conversation_id` (a required group context
  extension; participants refuse a Welcome where they differ from the room
  they asked to join).
- Words: a **room** is lasting (a voice channel, or a group's call
  button); a **call** is one call group's life in it. `call_id` names the
  call, and the call group's `group_id` is what joins sign.
- Two first joiners at once: the server's join route hands out the call
  (creating it under compare-and-set), so only one device creates the
  group; the other joins it.
- When the room empties, every device drops the group. The next join makes
  a new one. A call group is **never** written to sealed state (D70), K1
  backups or K2 transfer. A crash means leave and rejoin.
- A call group failure (a commit that will not apply, D54's fail-closed
  rule for control messages) is handled the same way: leave and rejoin. No
  group-fork analysis is needed because nothing is kept.

### Joining

1. The joiner asks the server to join (`POST /api/v1/rooms/{id}/join`). The
   server checks the account may use the conversation, as today, and
   returns the current participants and the call group's epoch.
2. The joiner makes a **fresh KeyPackage for this call only** (not from
   its uploaded pool, so busy rooms never drain it; made in memory, outside
   sealed state, D70) and signs
   `"veritra-b6-join-v1" | lp(group_id) | lp(nonce) | u64(expires_at) |
   sha256(key_package)` with its credential key (a new sign domain, like
   C7's). `nonce` is a fresh value from the join route; `expires_at` is at
   most 60 s ahead.
3. **Every device checks every leaf**, not only the committer:
   - the committer, before committing; every member, on each Add in a
     commit it receives; the joiner, on every leaf of its Welcome;
   - check: the leaf's credential and signature key equal that device's
     leaf in the parent group (`pm_crypto_group_member_signature_key`),
     and for a new Add, the join signature, `group_id`, nonce and expiry;
   - a KeyPackage already seen in this call is refused.
   A commit or Welcome that fails is refused: the member leaves and
   rejoins, the joiner does not join. Each failure is counted.
4. **Who commits:** the participant with the lowest leaf index commits
   within 200 ms; any other participant commits after 2 s if no commit has
   arrived. The server accepts one commit per epoch (compare-and-set on the
   room's epoch, the existing ordering rule for MLS messages) and rejects
   the rest with 409. The fallback delay is staggered by leaf rank
   (2 s, plus 500 ms per rank), so members do not all commit at once.
   Joins that arrive close together go in one commit.
   **Every call-group commit is staged:** stage, post, merge on 200,
   discard on 409 and work out again what still needs committing. The
   immediate-merge calls (`pm_crypto_group_remove_member`, `_self_update`)
   are never used for call groups.
5. The server accepts a Welcome only together with its winning commit (the
   existing commit bundle, `mls_handlers.go`). The joiner processes only
   that Welcome; everyone else processes the commit.

### Leaving

- A leaving device sends a signed "leaving" application message in the
  call group, tells the server, and stops sending. The server marks it gone
  at once, or 15 s after its SFU connection drops. Members act on either
  the MLS message or the server's notice.
- The committer rule above then commits a Remove. A device cannot remove
  itself in MLS, so the leave is always someone else's commit.
- If the leaver was the last device, there is nothing to commit.
- A member's app also removes a device whose SFU presence ended per the
  server; a false "gone" from the server only cuts that person off (denial
  of service), it never adds anyone.
- **Removed from the parent, removed from the call.** When a commit in the
  parent group removes a device (a leave, a revocation, a member removal),
  members commit a Remove for it in the call group too.

### Media keys

For each epoch `n` of the call group:

```
E      = MLS-Exporter("veritra-b6-media-v1", lp(call_id) | u64(n), 32)
K(s,t) = HKDF-SHA256(salt = "veritra-b6-sender-v1", ikm = E,
                     info = u32(leaf_index s) | u8(stream t), 32 bytes)
```

- `t` is the stream slot: 0 voice, 1 camera, 2 screen, 3 screen audio.
  Keys differ per sender and slot. Simulcast runs up to three encoders
  under one camera key, so S1 must confirm the IV includes the SSRC and
  never repeats.
- `K(s,t)` is handed to the frame cryptor's key provider for participant
  `s:t` at key index `n mod 16` (the key ring). The cryptor's own ratchet is
  off (window 0); MLS epochs are the only rekey.
- This mirrors RFC 9605 section 5.2 (an exporter secret per epoch, then a
  key per sender) but uses Veritra's own labels; it does **not** claim
  RFC 9605 conformance (see the next section).
- **Boundary exception.** C7 keeps every exporter output inside the core
  and has no stand-alone exporter call. B6 must break both rules: the keys
  have to reach libwebrtc's frame cryptor. Only `K(s,t)` leaves the core,
  never `E` or any other exporter label, and only through one call scoped
  to the label above. This needs the independent crypto review.

### Switching keys

- A device installs the new epoch's keys as soon as it merges the commit.
- A sender switches to its new key only after it has merged the commit
  (its own after the server's 200, or someone else's). Receivers that are a
  few hundred milliseconds behind drop a few frames; the cryptor's failure
  tolerance hides a short gap.
- Old keys stay in the ring for 10 s after a switch, then are removed.
  "Removed", not "wiped": keys pass through Dart, Java or Objective-C and
  libwebrtc's own copies, which we cannot zero.
- No periodic rekey is needed for nonce limits at call lengths, but every
  device self-updates once an hour to bound how long one key lives.

## Frame encryption ("SFrame")

| Option | What | For | Against |
|---|---|---|---|
| **A. The frame cryptor in `flutter_webrtc` (default)** | libwebrtc's AES-GCM frame transform (the format LiveKit uses: encrypted payload, a short trailer with IV and key index, codec headers left clear) | Already in our pinned dependency on all five platforms; no native code of ours | Not RFC 9605 on the wire; its format is set upstream |
| B. RFC 9605 SFrame in our Rust core | Our own encoded-frame transform per platform calling Rust | Standard format, all crypto in one place | Native transform code on five platforms; frames cross into Rust per packet |

Recommendation: **A now**, keeping the MLS-derived key schedule above,
which is the part that carries the security. Revisit B if libwebrtc ships
an RFC 9605 transform. *Confidence A is the right first step: about 75%.*

**Required cryptor settings (fail closed).** The defaults fail open:
`discardFrameWhenCryptorNotReady` defaults to false and key derivation to
PBKDF2, and the Darwin code reads a missing discard value as no. B6 sets:
discard on, no magic bytes (so no frame can skip decryption), `sharedKey`
off (per-participant keys), HKDF, ratchet window 0, and the cryptor attached
before the track is published. A frame with no key is dropped, never sent
or played in clear.

Details to check in S1, not assumed (the libwebrtc C++ was not read):
- which bytes stay clear per codec (VP8 key and delta frames, Opus, H.264
  NAL headers) so the SFU's packetizer still works;
- IV construction, so no IV repeats under one key across restarts of an
  encoder;
- the frame cryptor's "magic bytes" and failure-tolerance settings.

## Choosing the SFU

Licences below are from memory: **confirm each at licence review.**

| Candidate | Licence | Language | Notes |
|---|---|---|---|
| **LiveKit server** | Apache-2.0 | Go | Single binary, Redis only for several nodes, simulcast and SVC, webhooks, embedded TURN. Its E2EE uses the same frame cryptor as option A. Client: `livekit_client` (Apache-2.0) or its protobuf signalling written by us |
| Pion (`webrtc`, `interceptor`) | MIT | Go library | We would write the SFU (forwarding, NACK, congestion control, simulcast). Fits Go, no client SDK, much more work |
| mediasoup | ISC | C++ worker, Node.js or Rust | A library; we write signalling |
| Janus (VideoRoom) | GPL-3.0 | C | Combines with AGPL-3.0 (GPL-3.0 section 13). Plugin model, older API |
| Jitsi Videobridge | Apache-2.0 | Java | Needs Jicofo and XMPP; heavy for one node |
| Galène | MIT | Go | Small, standalone, own protocol; smaller community |
| str0m | MIT or Apache-2.0 | Rust | Sans-IO building block; we write the rest |

Recommendation (**O1**): **LiveKit server as its own container, like
coturn**, with the `livekit_client` Flutter package. *Confidence: about
65%; the alternative is a Pion-based `veritra-sfu` built here.*

How it fits "calls behind interfaces":
- A `RoomMedia` interface in `server/internal/webrtc` with one LiveKit
  implementation. The server **only mints short-lived join tokens**
  (signed with the SFU's API secret, the way it signs TURN credentials
  today) and receives the SFU's signed webhooks for presence. It never
  touches media and never connects to the SFU's media ports.
- The token names a random room name and a random per-join identity, not
  the conversation id or account id, so the SFU's own logs hold
  pseudonyms.
- Config: `PRIVATE_MESSENGER_SFU_URL`, `PRIVATE_MESSENGER_SFU_API_KEY`,
  `PRIVATE_MESSENGER_SFU_API_SECRET_FILE`. Unset means rooms answer
  `rooms_unavailable`, like calls without TURN.
- **D56:** peers never see each other's addresses (they talk only to the
  SFU). The SFU sees client addresses, as TURN does today. Both are the
  operator's.

## What the server and SFU still see

| Seen | By | Notes |
|---|---|---|
| Who is in which room, join and leave times | Server | Room is tied to a conversation; the server already knows its members |
| IP addresses | SFU (and TURN if used) | Same as today's relay |
| Track kinds (voice, camera, screen), resolution layers, bitrates | SFU | Needed to forward |
| Frame sizes and timing, key frames | SFU | Video size leaks motion; accepted |
| **Who is speaking** | SFU | Leaked by the audio-level header extension and by Opus DTX (no packets in silence). Default: extension off, DTX off (O4) |
| **What is said, roughly** | SFU | Opus variable bitrate packet sizes can hint at words. Default: constant bitrate for voice (O4) |
| Mute | SFU | A muted track stops sending. Accepted (O4) |
| Epoch mod 16 | SFU | The key index in each frame's trailer |
| Which track belongs to which device | Nobody | Each device announces its track ids in an MLS message in the call group; receivers attach keys by that, not by the SFU's names |
| Media content, keys, the real roster | Nobody | The roster shown in the app is the call group's MLS membership, not the server's list |

## Scaling limits

From `testing/evidence/C0-community-groups.md` (leaves are devices):

- An add commit is about 571 bytes; a Welcome grows about **206 bytes per
  leaf**. If room signals keep today's 48 KiB cap, the Welcome caps a
  room near 200 devices. A removal after many joins is about 83 bytes per leaf.
- Commit processing at 100 to 200 leaves is a few milliseconds per device.
  MLS is not the limit; bandwidth is.
- With DTX and the audio-level extension off, the SFU cannot pick active
  speakers, so it forwards every voice stream. At 32 kbit/s each, 50
  people means about 1.6 Mbit/s down per client and about 80 Mbit/s out
  of the SFU. *Estimate, confidence about 70%; S7 measures.*
- Video: simulcast (three layers); a client subscribes only to the tiles on
  screen. 25 cameras with 6 visible at about 300 kbit/s is about
  1.8 Mbit/s down per client.

Default caps (**O3**): **25 devices with video, 50 voice only.** Bigger
"stage" rooms are a later package.

## Mobile and desktop constraints

- **Phones:** foreground only until T42B (CallKit, Android Telecom) is
  approved. Locking the phone or leaving the app leaves the room (O5).
- **Android:** microphone needs a `microphone` foreground service while in
  a room; screen share needs MediaProjection consent each time (Android 14
  and later) and a `mediaProjection` foreground service. Both are
  platform-policy items for the owner.
- **iOS screen share** needs a Broadcast Upload Extension: a separate
  process with a small memory limit, and the media key would have to be
  shared with it through the app group. Default (**O6**): iOS can watch a
  screen share but not send one in the first release.
- **Desktop:** screen and window capture through `flutter_webrtc`'s
  desktop capturer on Windows and macOS (macOS asks for Screen Recording
  permission). Linux works on X11; Wayland needs the PipeWire portal.
  *Confidence Wayland works out of the box: about 50%; S1 checks.*
- **Codecs:** Opus for voice; VP8 with simulcast for video as the base
  every platform has. H.264 hardware encoding varies by device; AV1 later.
- **Battery:** phones subscribe to fewer and lower video layers.
- **Demo builds:** a local SFU on loopback only (D11, D12). The release
  gate does not change: rooms are off in release builds with the rest of
  messaging.

## Threats

| Threat | Result |
|---|---|
| Server adds a stranger's device | Refused: its key does not match a leaf of the parent group |
| Server adds a hidden device of a real member (the L1 gap) | **Passes today**, as for messages: the parent group holds that device. L1 closes it. The device shows in the room's roster |
| Server replays an old join | Refused: the signature binds the call group's id, a fresh nonce and a 60 s expiry; a KeyPackage seen before is refused |
| Server hands a joiner a fake group of its own leaves | Refused: the joiner checks every Welcome leaf against the parent group |
| Malicious member adds a stranger | Refused: every member checks every Add it receives |
| Device removed from the conversation keeps listening | No: the parent group's removal triggers a call-group Remove |
| A member fakes another sender's frames | **Possible**: every member holds every sender's key (as in DAVE). Accepted; per-frame signatures are a later option |
| SFU replays frames within an epoch | Possible to a small extent; S1 checks whether the cryptor refuses repeated IVs. Accepted if not |
| A lost commit race forks the group | No: commits are staged and merged only on the server's 200 |
| Server or SFU keeps forwarding to a device that left | It holds only old keys; the next epoch locks it out |
| Server falsely reports someone left | That person is cut off (denial of service only) |
| Server withholds a leave | Members still get the leaver's encrypted "leaving" message and commit the Remove. If the leaver crashed, it keeps old keys until the SFU drops it |
| SFU reads or changes media | It cannot decrypt; a changed frame fails AES-GCM and is dropped |
| SFU learns who speaks and roughly what | Reduced by O4 (constant bitrate, no DTX, no audio level) |
| Media key copied out of memory | Keys live in app and libwebrtc memory during the call (the boundary exception); removed 10 s after each switch and when the call ends |
| Frames sent in clear before a key is set | No: discard-when-not-ready on, cryptor attached before publishing |
| Two members commit at once | The server takes one per epoch; the other retries on the new epoch |
| A member's app is malicious | It can record what it hears and fake others' frames (above). It cannot add devices from outside the parent group: the others refuse the commit |
| Joining member hears earlier talk | No: every join is a new epoch (O7) |

## Build steps

| Step | What | Counter | Done when | Route |
|---|---|---|---|---|
| S0 | This design | none | Merged after independent review | Opus designs |
| S1 | Spike, not merged into the product: two and three loopback peers with the frame cryptor and fixed keys on Linux, Windows, Android, iOS, macOS; check clear bytes per codec, IV rules, Wayland capture | none | A note in `testing/evidence/B6-spike.md` per platform: works or not | Sonnet; result decides O2 |
| S2 | Crypto core: the media-key call (exporter label `veritra-b6-media-v1` plus the per-sender HKDF, `K(s,t)` out only), the join sign domain `veritra-b6-join-v1` and its verify, group context extension check. Vector `testing/vectors/b6-media-v1.json`; Rust, Go and Dart check it | **one crypto ABI bump**, number reserved by the coordinator | Rust tests: keys differ per epoch, sender and stream; a removed device cannot derive the next epoch's keys; the join signature cannot verify as an MLS or C7 signature; `docs/crypto.md` entry | Sonnet; **independent crypto review before merge** |
| S3 | Server: rooms and participants tables, join and leave routes, per-epoch commit compare-and-set, `RoomMedia` interface and LiveKit tokens, signed webhooks, retention sweep, room caps, admission limits, config and startup checks, `operations.md` | **one server migration**, number reserved by the coordinator | Go tests (below), `go test -race`, `go vet`, `govulncheck`, `scripts/test` | Sonnet; Opus review |
| S4 | Deployment: SFU in Compose and the k3s base with its ports and network policy, `scripts/smoke-deploy.sh` joins a room, `THIRD_PARTY_NOTICES.md` | none | Smoke passes against a real SFU container | Sonnet; owner approves O1 first |
| S5 | App engine: join, commit roles, key install and wipe, roster from MLS, leave and rejoin on failure, in memory only | none | Dart tests (below); `scripts/check-demo-boundary.sh` passes. Fail-closed cryptor settings asserted | Opus review (MLS ordering) |
| S6 | UI: room screen, tiles, mute, desktop and Android screen share, English and Serbian strings | none | Widget tests; CI green on every platform | Sonnet |
| S7 | Evidence: demo e2e with three clients and a local SFU; bandwidth and CPU at 5, 25 and 50 voices | none | `testing/evidence/B6-group-calls.md` | Sonnet; phone runs wait for G24-era devices |

Order: S1 and S2 can run together; S3 after S2's ABI is fixed; S4 after
O1; S5 after S2 and S3; S6 after S5.

## Test plan

- **Vectors:** one file, checked by Rust, Go and Dart: exporter inputs, `E`,
  `K(s,t)` for several leaves and streams, join signatures valid and
  invalid.
- **Rust:** domain separation of the new labels; output only for the B6
  label; outputs zero on failure.
- **Go:** a non-member cannot join; a DM room and a channel room; caps
  enforced; one commit per epoch under concurrent posts; webhook signature
  checked, a forged one refused; tokens carry no account or conversation id;
  no room id, device id or IP in logs beyond the existing request line;
  rooms swept at end.
- **Dart, with a fake SFU and in-process groups:** join and leave each move
  the epoch and keys; a KeyPackage whose key differs from the parent leaf is
  refused, by the committer, by every receiver and by the joiner; a Welcome
  with a leaf outside the parent group is refused; a replayed or expired
  join is refused; a 409 discards the staged commit (no fork); a parent
  removal leads to a call Remove; a frame before key install is dropped; a forged "left" removes but never
  adds; the roster follows MLS, not the server list; old keys wiped after
  10 s; no key in logs or local storage; a failed commit leads to leave and
  rejoin.
- **Wire check:** capture traffic at the SFU in the demo and show that the
  Opus and VP8 payloads do not decode, and that voice packets are a
  constant size.
- **By hand, per platform:** join, leave, mute, screen share, network change,
  phone locked (expect leave on phones until T42B).

## Owner questions (defaults in bold)

- **O1. SFU.** **LiveKit server (Apache-2.0) as a separate container, and
  the `livekit_client` Flutter package.** Alternative: a Pion-based SFU we
  write. Both are new dependencies.
- **O2. Frame format.** **The frame cryptor already in `flutter_webrtc` now;
  RFC 9605 later if libwebrtc offers it.** Alternative: our own RFC 9605
  transform on five platforms.
- **O3. Room size.** **25 devices with video, 50 voice only.**
- **O4. Hide speaking patterns.** **Constant bitrate voice, DTX off,
  audio-level extension off; mute stays visible.** Costs about 32 kbit/s per
  voice stream even in silence.
- **O5. Phones in the background.** **Foreground only until T42B is
  approved.**
- **O6. iOS screen share.** **Watch only in the first release.**
- **O7. Rekey on join.** **Yes, always** (newcomers never hear earlier talk;
  costs one commit per join).
- **O8. Who can open a room.** **Anyone who may post in that conversation
  or channel** (C2 and C4 rules apply).

## Build status (2026-11-11)

Built: S2 (crypto ABI 22: `pm_crypto_group_b6_media_key`, join sign domain,
vector `testing/vectors/b6-media-v1.json` checked by Rust, Go and Dart); S3
(migration 0080, `/api/v1/rooms` join, offer, commit, commits, state, leave
and webhook, `RoomMedia` with a LiveKit implementation that signs tokens and
checks webhooks without a new dependency, config, retention sweep, caps);
S4 as an example only (`deploy/livekit/livekit.example.yaml`,
`docs/operations.md`; nothing in the default stack); S5 (`mobile/lib/calls/
room/`: the engine, the native MLS adapter, the API client; fakes-based and
real-MLS tests); S6 (`features/calls/room_screen.dart`, strings in English
and Serbian, a group-call button shown only when the demo host sets
`AppState.roomSession`).

Choices and deviations from the text above:

- **Server-issued call group id.** The server picks the random 32-byte group
  id when it creates the room and returns it on join; the first device
  creates the MLS group with it. Joins still sign the group id and a nonce,
  so nothing depends on who chose the id.
- **Join offers go through the server.** A joiner posts its call-only
  KeyPackage and signature (`POST /rooms/{id}/offer`, nonce issued by the
  join route, single use); members read them from the room state. The server
  cannot check the signature; every member does.
- **Leave notice.** A leave is the server's notice (leave route, SFU
  webhook, or a 12-hour stale seat); the signed "leaving" MLS message is not
  built. A false notice can only cut someone off.
- **Receivers check an Add by identity and signing key against the parent
  group plus a valid signed offer on the server's list, not by KeyPackage
  hash** (the core does not return it yet). The committer checks the whole
  signature. A KeyPackage reused in one call is refused.
- **Media key by identity.** The core finds the sender's leaf from its
  account and device id, so the app never guesses a leaf index.
- **Call-only KeyPackage** lives in the device's provider storage until the
  next prune (it is not in the uploaded pool).

Review fixes (2026-11-11): the engine drops only a group it created or
joined (the group id is the server's word, and the core's `delete_group`
must never run on it), refuses a group id that is not 32 bytes, and the
committer refuses an expired offer (receivers keep 120 s of slack). The
server refuses room reads, offers and commits from a seat whose account is
no longer a member of the conversation; leaving stays open.

Not built: the media transport (the SFU client, mute and screen share
controls behind `RoomMediaControls`, and the frame cryptor key provider
behind `FrameKeySink`; needs the `livekit_client` package and a licence
review); the production factory that sets `AppState.roomSession` in
`main_demo.dart`; the call-group context extension binding `call_id` (core
change); S1 spike and S7 evidence; Android foreground services and iOS
broadcast extension. **Before the factory is wired:** a call group must
stay out of sealed state (D70), K1 backups and K2 transfers. Today it sits
in the same device provider as the conversations, so the next
`seal_changes` while a call is open would write it; the core needs to keep
call groups out of seals (or hold them in a separate handle) first. Needs
the independent crypto review before S2 lands.
