# Crypto Boundary

The selected production direction is MLS through OpenMLS. This Rust crate now
pins OpenMLS 0.9.2 and contains a tested native core for signed key packages,
group creation/join, and authenticated application messages. It also exposes a
versioned C ABI and Rust-side credential/key-package boundary types. ABI v9 has
tested opaque device handles, zeroing owned buffers, credential public-key
export, domain-separated enrollment proofs, key-package creation, state sealing, and
rollback-checked restore, plus group create/join/add/remove/update, staged
membership commits, commit processing, and application encrypt/decrypt. The legacy handle-free
encrypt/decrypt entry points still return `PM_CRYPTO_UNAVAILABLE`, so mobile code cannot
treat the native core as production crypto before the full path is wired and
reviewed.

The server now reserves final account/device IDs before key generation and
atomically verifies and consumes a signed enrollment proof covering the server
challenge, Ed25519 public key, and SHA-256 key-package commitment. The Flutter
client models this preflight, and its low-level Dart FFI binding requires ABI
version 24 exactly (`native_crypto_bindings.dart`) and uses the owned
device/buffer calls. Native libraries are packaged for Android/iOS, while the
production service remains behind the release gate.

The public header is `crypto/rust/include/veritra_crypto.h`, which pins
`PM_CRYPTO_ABI_VERSION` at 24. Among other things it defines:

- account/device-bound opaque handles with exactly-once destruction
- library-owned, zero-on-free output buffers
- enrollment proofs signed with the MLS credential key over a fixed
  `veritra-enrollment-proof-v1` prefix (no raw-challenge signer since ABI 9)
- sealed provider-state export and rollback-checked restore
- conversation-bound Welcome processing and credential-bound member addition
- the versioned protocol identifier `mls10-openmls-v1`
- sender binding (ABI 5): `pm_crypto_group_decrypt` takes the claimed sender
  account and device and returns `PM_CRYPTO_SENDER_MISMATCH` (-5) when the
  authenticated MLS credential differs (decision D25)
- staged membership commits (ABI 6, card I51):
  `pm_crypto_group_stage_commit` builds one commit adding and removing any
  number of devices without merging it; `pm_crypto_group_merge_pending_commit`
  and `pm_crypto_group_clear_pending_commit` settle it after the server's
  answer; `pm_crypto_group_epoch` reports the epoch and whether a commit waits.
  Groups keep two past epochs for decryption only (`max_past_epochs`).

Key-package size checks mirror the server transport boundary (64 bytes through
48 KiB). Passing that check does **not** verify an MLS key package. The server
also parses every uploaded device key package (setup, register, device-link
v2 and v3 claims, account recovery, key-package publish) as one bare RFC 9420
KeyPackage, the bytes `MlsDevice::create_key_package` returns: version mls10,
suite 0x0001 with 32-byte keys and 64-byte signatures, a basic credential with
a non-empty identity, a `key_package` leaf with its lifetime, well-formed
extension lists, minimal vector lengths and nothing after the signature
(`server/internal/mlswire`, TASK-172). It verifies no signature and does not
bind the credential to the enrollment signing key. For an account with a
signed device list, L1-3 adds the Q-1 gate: the leaf signature key must be the
key the list names for the device (see the L1-3 change-log entry); clients
still validate every key package they use.

OpenMLS 0.9.2, `openmls_rust_crypto` 0.6.0, and their supporting crates are
exactly pinned (Rust 1.91 or newer). All 205 locked third-party packages declare
compatible license choices recorded in `THIRD_PARTY_NOTICES.md`. Since ABI 10
(D70) sealed state is format 4: a root plus one record per owner, described
in "Sealed state, format 4" below. Format 2 and 3 blobs are read only by the
one-way migration at activation. Version 1 blobs written under OpenMLS 0.8.1
and unknown versions fail closed, with their own restore code since ABI 9.
No debug feature that exposes message content or cryptographic material is
enabled.

### Sealed state, format 4 (ABI 10, D70)

The state is no longer one blob. It is a root, kept in the existing
singleton row, and one record per owner in `local_crypto_records` (schema
16): the device record (kind 1: signer, K2
transfers), one record per group (kind 2, id = conversation id) and one per
key package (kind 3, id = hash reference). Key pairs that no group owns are
dropped at migration; seal refuses them and restore rejects them in the
device record. Design: [D70](designs/D70-per-group-sealed-state.md).

- **Record.** `"PMMLSST1" || u16 4 || u8 kind || u64 generation ||
  u16 account_len || account || u16 device_len || device || u16 id_len ||
  id || nonce12`, then `u32 len || AES-256-GCM ciphertext` under the
  existing state key, with the whole header as AAD. Kind 0 is the root.
- **Root.** Lists the signer's public key and, for every record, its kind,
  id, generation and the SHA-256 of the sealed record. It is resealed in
  every transaction at the new generation, which must be the stored counter
  plus one.
- **Writes.** `pm_crypto_device_seal_changes` returns the root and only the
  records that changed (upserts and deletes). The app applies them in the
  same SQLite transaction as the root and the change that caused them
  (message, cursor, outbox). Every write that replaces the root applies its
  changes, including rollbacks and the D54 retry. A full write
  (`saveCryptoState`) replaces all records.
- **Restore.** The app reads the root and every record in one transaction,
  then `pm_crypto_restore_begin` (generation at least the minimum, and the
  app requires it to equal the stored counter), `pm_crypto_restore_add` per
  record, `pm_crypto_restore_finish`. A missing, extra, duplicate, stale,
  foreign (other account or device), altered or wrong-key record fails the
  whole restore. `finish` and `pm_crypto_restore_abort` spend the token.
- **Caps (plaintext).** Root 16 MiB and 200,000 entries; device record
  1 MiB; group record 32 MiB, 4 MiB per value, 10,000 values; key package
  record 256 KiB; at most 1,000 key packages. A sealed record may be up to
  4 KiB larger. A record over its cap fails the seal with
  `PM_CRYPTO_RECORD_LIMIT` (-8), which names its kind and id; nothing is
  sealed and the app restores the committed state. The change-set output
  is bounded at 128 MiB.
- **Migration (one way).** At activation only, a format 2 or 3 blob goes
  through `pm_crypto_device_migrate_v3`: every check of the old restore, the
  counter must equal the stored one, inactive groups and key pairs no group
  owns are dropped, and the result is checked against the input. The app
  then seals every record at counter + 1 and stores the new root and all
  records in one compare-and-swap transaction (`commitCryptoMigration`:
  the old blob must still be stored, unchanged), deleting any records found
  beside the old blob. The device is then restored from what was stored.
  A crash at any step leaves either the old blob or the full new state.
  Older builds refuse a format 4 root (`stateFormatUnsupported`).
- **Groups that end.** Applying its own removal drops a device's group and,
  with the next seal, its record. `pm_crypto_group_delete` drops a group
  the user deleted. A missing group behaves as an inactive one did before:
  a peer message to it is a D54 placeholder, `groupEpoch` answers null, and
  a commit bundle for it settles.
- **Key packages.** `pm_crypto_device_prune_key_packages` drops packages
  whose `not_after` passed more than 24 hours ago. A Welcome for a key
  package this device does not hold, or one that expired, fails with
  `PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE` (-9, D74) before anything is
  consumed; the app records an `invalid` row keyed
  `welcome-unavailable:<syncEventId>:<mlsMessageId>`, shown as "Couldn't
  join this chat. Ask a member to add you again.", and sync moves on.

**OpenMLS upgrade checklist.** Any OpenMLS (or `openmls_rust_crypto` /
`openmls_memory_storage`) version bump must re-check the storage labels
and key shapes in `LABELS` (`crypto/rust/src/mls/storage.rs`) and the
storage-method list in its routing test. A label the classifier does not
know makes every restore fail closed with `InvalidState`.

Before production message sending:

- connect the native ABI to the mobile protected record; the Flutter store now
  atomically writes the 32-byte state key, sealed state envelope, monotonic
  counter, and sync cursor through Android Keystore-backed encrypted storage or
  iOS Keychain (`ThisDeviceOnly`) storage
- add MLS test vectors
- obtain independent protocol and mobile-binding review

## Proposed designs

Proposed, not yet built. Nothing below changes the ABI, payloads or schema
until the package that builds it lands and adds its change-log entry.

- [K0: one long-lived key](designs/K0-long-lived-key.md): a recovery key
  only the user holds; backups sealed to its public half; one history
  container for backups (K1) and new-device bundles (K2); restores create
  a new device instead of cloning MLS state. Recovery operations now target
  a later ABI (L0 uses v7). L0 implements secret-authenticated linking below;
  K2 must use a new transcript version when adding its transfer key.
- [C0: community group layout](designs/C0-community-groups.md): one shared
  MLS group for a community's open channels plus one per private channel,
  with a measured join cost ([evidence](../testing/evidence/C0-community-groups.md)).
  It needs `channel_id` as a reserved top-level context key in the W7
  payload: required in `community_shared` conversations, absent elsewhere,
  and invalid on a mismatch with the envelope. It must land before any W8
  sender.
- [C3: private channels and community info](designs/C3-private-channels-and-info.md):
  names, topics and icons of communities, categories and channels as
  encrypted W11-style records; a private channel's key travels only in its
  own group. Its W7 payload types `info_key`, `info_key_request` and
  `info_update` are registered (§4; change log "C3", 2026-11-08); senders are
  not wired yet.
- [C7: history for new members](designs/C7-channel-history.md) (revision 7, reviewed; build step 2,
  the primitives, is in as ABI 13 and wired nowhere; the rest is planned, not built): every community message becomes a 68-byte `C7R1`
  MLS reference plus a sealed body (an amendment of the W7 §1 framing, VAP1
  unchanged inside the body); hidden W7 types `history_change`,
  `history_sync`, `history_sync_request`; rekeys derived from the MLS
  exporter at each removal epoch (owner, 2026-11-07); and ABI 13 (step 2,
  see the change log), subject to independent crypto review: commit
  processing and merge that return whether the commit removed or added
  members, the new epoch and a fixed-label exporter root, a decrypt that also returns the epoch, a
  member signature-key read, an `inspect_commit` refusal of a changed leaf
  signature key, credential-key sign/verify over a domain allowlist, and
  HKDF plus AES-256-GCM sealing on existing dependencies.
  Nothing here changes until C7 lands with its change-log entry.

## Device linking

[L0 device link v2](designs/L0-device-link-v2.md) specifies the secret-keyed
tags; [L1-3](designs/L1-3-link-commitment.md) specifies the current protocol,
`veritra-device-link-v4` on the K2 route, which adds commit-then-reveal. Both devices use their configured canonical
server origin. The old device generates a 128-bit secret; QR and manual
input carry its 26-character base32 encoding. HTTP carries only a one-way
locator. The old device verifies the claim tag before asking for the typed
safety code; the new device verifies the separate approval tag and its
reserved identity before saving a session. JSON API redirects are refused.
Legacy links must be recreated. Existing account/device sessions remain valid.

SAS strength (TASK-010, TASK-048, D100). The SAS is 8 digits, about 26.6
bits. The SAS, the claim tag and the approval tag are MACs keyed from the
128-bit QR secret, so a relay without the secret can evaluate none of them.
The case L0 left open is a leaked secret: someone who saw the QR code and
also controls the relay. That attacker can forge both tags, so the SAS is
the only check left. Before L1-3 it could also be ground, and more cheaply
than the audit assumed: the old device built its transcript from the nonce
returned on refresh, so the relay could grind that nonce with HMACs alone
(4 of 8 digits after 3,645 tries in a test; all 8 in minutes). Protocol v4
(L1-3, ABI 18) adds commit-then-reveal. The old device commits to a fresh
random before the new device exists. The new device sends its own fresh
random in the claim. The old device reveals its random only after its native
accept has fixed that claim, and the new device shows the code only once the
random opens the commitment. Both codes depend on a random the relay had to
fix before it saw it, so it gets one guess of about 10^-8 per run. The 8
digits are kept (D100). The v2 derivation was removed from the ABI. Any
transcript change still needs a new protocol string and vector
(`testing/vectors/device-link-v4.json`).

### What L1 must provide (TASK-006)

The crypto core now checks the shape of every commit and Welcome (Basic
credentials, well-formed and unique device identities, no identity change
on update, the own leaf, a member inviter). It cannot decide who may hold a
key: the server publishes key packages, so it can still invent a device for
a real account. L1, the signed approved-device list, must give the core:

- a trust anchor: per account, the set of `(device_id, signing key)` pairs
  the account's own devices signed, verifiable without trusting the server,
  with rollback protection (a version or chain) so removed devices stay out;
- a check on every added leaf, update-path leaf and Welcome roster member
  that its identity and signing key are in the current list for its account;
- authorization of the committer and of the Welcome sender: a member whose
  pair is in that list (and, for conversation roles, allowed to change
  membership);
- the expected roster for a Welcome, from the conversation's participants,
  so a join into a server-built group of look-alike devices is refused;
- a defined result when the list is unavailable or stale: fail closed for
  adds and joins, with a visible state instead of silent acceptance.

With L1 the identity-only check on past-epoch senders (TASK-008) can also
compare signing keys.

**Built: L1-1 (crypto, ABI 14), L1-2 (server, migration 0051) and L1-3
(mobile, local schema 26); see the change log.** The design is
[`L1-approved-device-list.md`](designs/L1-approved-device-list.md).
**L1-1, the crypto layer (ABI 14).** The signed list format
and its verifier, the signing calls, the recovery signer, the expected-key
add and the per-leaf pair outputs are in; see the change log entry "L1-1"
below. The trust anchor still has no caller: pins, the add gate, the holds
and the message verdicts are L1-3 (mobile), the routes are L1-2 (server).

### Rejoining a conversation

A device removed from a conversation and later re-added (an account that
leaves and is invited back) no longer stores the old group: since ABI 10
(D70) applying its own removal commit drops the group and its record, so
the Welcome is a fresh join. `join_group` (`pm_crypto_group_join`) still
lets a Welcome replace a stored group that is inactive, which only a state
restored from before the drop can hold. `pm_crypto_group_delete` is for a
chat the user deletes, and only for that: the app never calls it on a
removal, a server event or a Welcome, so the server cannot use it to make a
device drop an active group. A leave the app has not yet applied locally
(it runs at the start of the next foreground sync pass) may also run
when a Welcome for that conversation arrives, but only as the user's own
deferred leave, never on the Welcome's word. The Welcome then has the trust of any fresh join, which
includes the L1 gap above: the core checks its structure, not who may be in
the group or who may invite.

A Welcome from before the user's own leave is not a re-add. The app notes,
at leave, a floor for that conversation in the local setting
`mls.left_floors` (scoped like the leave note, no schema change). The floor
is the id of the leaver's own `membership.left` sync event, which the server
returns as `event_id` in the `DELETE /members/me` response (an additive
field). Welcomes are stored only for member devices, in the transaction that
adds them, so a Welcome with a lower id predates the leave and one with a
higher id is a real re-add: the floor is exact, and a re-add is never
skipped. A Welcome for this device at or below the floor is skipped: the sync
cursor moves past it, nothing joins, and its key package is still replaced.
This closes the race where a pass that fetched the add-Welcome before the
leave applied it after the group was dropped and the note cleared.

A server that returns no `event_id` (an older one) is asked for its newest
sync event id instead (`latest_event_id` on an empty page), which is at or
above the leave's own event. That floor is not exact: a Welcome created after
the leave but before the app reads the bound would also be skipped, a window
of one request. If that read fails too, the newest event id the running pass
of the same session has fetched stands in: it covers the page the pass holds,
not events it has yet to fetch or a fetch still in flight, and a pass from
another session is ignored.

A floor is dropped lazily: each write of the floors (the next leave) removes
every floor at or below the committed sync cursor, since a pass skips events
at or below the cursor and such a floor can no longer matter. Until then a
reached floor stays stored; that is harmless, as no event at or below the
cursor is applied again.

An active stored group is never replaced, whoever sends the Welcome and
whatever its epoch. A Welcome cannot prove the device was removed. If it
could replace an active group, a malicious server together with any
member, even one already removed, could make the device delete its real
group for a fork at an epoch of their choosing. Withholding events alone
cannot do that. The refusal comes before the Welcome is staged, so the
group and the key package are both kept.

So a device removed while offline must be given its removal commit before
its new Welcome. The server does not do that yet: the re-add upsert in
`server/internal/storage/mls_group_store.go` (`ON CONFLICT ... DO UPDATE`)
overwrites the old roster window, `joined_after_event_id` and
`removed_after_event_id`. Sync then hides the removal commit, the Welcome
is refused, and the device's sync stops under I33. The server change is
pending.

Tests: `crypto/rust/tests/rejoin_after_removal.rs`.

## Member removal send hold (D68)

After a member is removed, application sends to that conversation wait,
unencrypted, until the MLS commit that removes the member's devices is
applied on this device, so nothing is encrypted to them. A hold starts when
this device removes a member, when the server's pending-changes list
(`GET /api/v1/mls/pending-changes`) shows a removal, or while a queued
commit bundle removes a member. Holds are kept per device across restarts
(`_removalHolds` in `mobile/lib/core/app_state.dart`).

**Release.** A hold set before a pending-changes read is released when that
read no longer lists the conversation (the unlisted marker records the
first such read), and a complete sync fetch that started after that read has
finished, and no MLS work for it is queued. Then it is released when the
group is gone, the local epoch is past the listed one (or the server never
listed it), or every removed account is a member again. A read the server
cut at its overall cap may leave conversations out, so it releases nothing
it leaves out. The response says so in the top-level `list_truncated` flag.
One conversation over its own cap is flagged `truncated` on its item only
and does not hold the others. Without the flag (an older server) a read
whose items are all `truncated` is taken as cut. A conversation whose group
state cannot be read keeps its hold; the others are still looked at.

**Premises.** The release is sound only while all three hold:

1. The server writes a commit, its sync event, the roster change and the new
   epoch in one transaction. A read that no longer lists a removal means its
   commit's event is already in the stream.
2. Reconcile reads pending changes and updates holds in one serialized pass,
   and a hold is compared only after a full sync fetch that began after the
   read. That fetch then brought in every commit the server held at it.
3. An MLS control message that cannot be applied stops sync at its event
   (I33). The fetch then never completes, so the hold stays.

**Residual.** The release trusts the server's roster. Device revocation and
account deletion drop a removed device from the roster without a commit, and
no FFI call lists a group's members, so the client cannot confirm the device
really left the group. A malicious server could release a hold early this
way. The L1 gap above covers the same trust.

## Message size

Three limits apply to an MLS application message, smallest first:

| Limit | Bytes | Where |
| --- | --- | --- |
| App payload (padded) | 65,536 | `app_payload.dart` `_maxPayloadBytes` |
| Sendable plaintext | 733,184 | `maxSendablePlaintextBytes` in `native_crypto_bindings.dart` |
| FFI plaintext / ciphertext | 1,048,576 / 1,052,672 | `MAX_MESSAGE_BYTES`, `MAX_CIPHERTEXT_BYTES` in `ffi.rs` |

The message routes read at most 1 MiB of JSON (`readLimitedJSON` in
`server/internal/httpapi/api.go`), with the ciphertext base64-encoded inside
it, so the largest ciphertext the server can take is about 768 KiB. The
sendable plaintext is derived from that: reserve 64 KiB for the other JSON
fields (ids, metadata, attachment refs), leaving (1 MiB - 64 KiB) * 3 / 4 =
737,280 ciphertext bytes, then subtract a 4 KiB margin for MLS framing (312
bytes measured). `NativeCryptoDevice.encrypt` refuses anything larger with
`NativeCryptoError.plaintextTooLarge` before encrypting, so no ratchet step
is spent on a message that cannot be sent. A test encrypts exactly the cap
and checks that a full request body stays within 1 MiB. The server limit is
not raised; if it changes, change the derivation with it.

## L2 padding (ABI 23)

Design: [`L2-server-learns-less.md`](designs/L2-server-learns-less.md),
step L2-1, defaults accepted (D106). What each uploaded blob does now:

| Blob | Size the server sees | Where the padding is |
| --- | --- | --- |
| Application message | 256-byte multiple | `VAP1` (256-byte buckets) inside an MLS `PrivateMessage`, itself padded to 256 by MLS |
| Commit | 256-byte multiple | Groups use OpenMLS's default pure-ciphertext wire format, so every commit is a `PrivateMessage` padded by `padding_size(256)`. The design's guess (65 %) that commits went out as `PublicMessage` was wrong; a Rust test pins `PrivateMessage` for add and remove commits |
| Welcome | L2 bucket (below) | **New.** A pad extension in the GroupInfo, which is encrypted and signed |
| Key package | L2 bucket | **New.** A pad extension in the signed key package |
| K1 backup, K2 history transfer | Their own buckets | Already padded (`history.rs`, `padded_size`) |
| `history_sync` (C7) | Exact | **Not padded, on purpose.** The server tells a `history_sync` body from a channel post by its exact size (`c7SyncBodySize`, `server/internal/storage/c7_body_store.go`) to exempt it from C2 and slow mode. Bucketing it would remove that exemption. This is a conflict between L2-1 and the C7 design; it needs a C7 decision (for example, a size rule over buckets plus a client-side check), not a quiet change here |
| Attachments | Manifest v2 buckets | Unchanged (D60-D63) |

**The bucket rule.** For a blob of `n` bytes: the next multiple of 256 (at
least 256) while that is at most 4096; above, the next power of two, up to
8 MiB (its base64 still fits the 12 MiB commit-bundle route with the commit
beside it). A blob above 8 MiB is not padded. `pm_crypto_l2_padded_size`
exports the rule; `testing/vectors/l2-padding-v1.json` holds the edges
(0, 255, 256, 4096, 4097, the cap and above) and one padded key package,
checked by Rust (`crypto/rust/src/l2_tests.rs`), Go
(`server/internal/mlswire/l2_padding_test.go`, which re-states the rule and
runs the structural key-package check on the padded package) and Dart
(`mobile/test/l2_padding_native_test.dart`, through FFI).

**The pad.** One MLS extension of type `0xF0A2` (private use; C4 uses
`0xF0C4`) whose data is zero bytes. RFC 9420 requires a key package's
extensions to be listed in its leaf's capabilities, so every leaf now lists
`0xF0A2` next to `0xF0C4` (`c4::leaf_capabilities`). Nothing requires the
extension of other leaves or of the group context. A pad whose data is not
all zero, or longer than 8 MiB, is refused: in a key package being added
(sender side) or in a received commit's Add (`inspect_commit`), and in a
Welcome's GroupInfo at join. An outer pad the server could strip, or one
outside the MLS structure, would not help: the server can parse the MLS
vector lengths.

**Key packages.** The unpadded size depends only on the credential, so
`create_key_package` first builds a throwaway package with the same
credential and fresh keys in an in-memory provider that is never stored,
then computes the pad that lands exactly on a bucket (the first reachable
one, since a length prefix step can skip a bucket by one or two bytes).

**Welcomes.** The GroupInfo's size is known only after the commit is built.
`stage_commit_with_record` (every app path that adds devices) stages the
commit with a 64-byte pad, measures the Welcome, clears the staged commit
and stages it again with the pad that reaches the bucket; a third stage
happens only when a vector prefix crosses 16 KiB, and a bucket a prefix
step jumps over is replaced by the next one. Building writes nothing;
each discarded stage consumes one handshake ratchet generation, which
receivers skip as they skip a lost message (well within OpenMLS's
forward distance). Add-only commits cost about 7 ms to stage at 1,000
leaves (C0), so the extra stage is small. If padding cannot reach a bucket
after six stages, which no tested size does, the commit goes with the
64-byte pad: padding never blocks a membership change. The deprecated
`pm_crypto_group_add_member` (tests only) is not padded.

**What it buys.** Sizes of key packages and Welcomes no longer show
credential lengths, the C4 record size or the exact tree size. The server
still learns the roster from the commit bundle's `added` and `removed`
lists (D28), and the count of Welcome recipients from the Welcome's
per-recipient secrets, so against the server the Welcome pad mainly hides
the record and credential contents' sizes; against a network observer it
hides the tree size too.

**Compatibility.** Tested: an ABI 23 core adds unpadded key packages and
joins unpadded Welcomes
(`unpadded_packages_are_still_added_and_bad_pads_refused`). Expected but
**not tested** against an ABI 22 build: an ABI 22 core (the same OpenMLS
0.9.2) accepts a padded key package, because the package's own leaf lists
`0xF0A2` in its capabilities, and a padded Welcome, because OpenMLS keeps an
unknown GroupInfo extension without acting on it. This departs from the
design's test plan line "an older library refuses a padded blob (fail
closed)": padding is meant to need no lockstep upgrade, and the reviewer
has to accept that or ask for the cross-version test (build origin/main's
core and feed it this branch's blobs). The only new receive rule is the
malformed-pad refusal, which no honest client of either version triggers.
The app still pins the exact ABI (23), as for every bump.

## Sealed sender boundary (ABI 23, L2-3)

`pm_crypto_group_decrypt_sealed` decrypts an application message and
returns the sender MLS authenticated (account and device ids), comparing
nothing the server sent: D25's binding becomes "MLS says" for this call.
A past-epoch message counts only while its sender is still a member
(`PM_CRYPTO_SENDER_REMOVED`), as in `pm_crypto_group_decrypt`, which keeps
its D25 check unchanged. Bound in Dart as `NativeCryptoDevice.decryptSealed`
and tested in Rust and Dart; **nothing in the app or server uses it yet.**
It is in ABI 23 so that sealed delivery needs no further ABI bump.

ABI 23 recorded two facts that stopped the rest of L2-3: every message is
franked (so sealed sending would apply to none), and the credential must
verify in Go as well as Rust. The owner chose option B, VOPRF tokens (D122;
the A and C options are in Git history). The design follows.

### Sealed sender with VOPRF tokens (D122, crypto ABI 26, design 2026-11-12)

Owner decision D122 chose option B: Privacy Pass style tokens from an
oblivious PRF (RFC 9497). This section is the design; "As built" at its end
says what exists. Everything is behind the server switch
`PRIVATE_MESSENGER_SEALED_SENDER=1` (off by default). The two open facts the
ABI 23 entry recorded are answered: sealed messages stay reportable through
designated-verifier tags over the franking commitment, one per pinned
instance owner ("Franking a sealed message"), and the credential verifies in Go and Rust through one library
on each side ("Libraries").

**What it protects.** For an ordinary application message in a DM or a
plain group, the server stores and fans out the ciphertext without the
sending account or device. The server still knows the conversation, that
the poster is one of the accounts it gave tokens to for that conversation
and day, and everything listed under "What still leaks".

#### Construction

- **Primitive.** RFC 9497 POPRF (mode `0x02`, partially oblivious, so the
  server proves its evaluation with a DLEQ proof and binds public `info`),
  suite `ristretto255-SHA512`. One proof covers a batch (RFC 9497 §2.2).
  Inputs, blinds and the token output stay with the client; the server sees
  blinded elements at issuance and an unblinded `(nonce, output)` pair at
  redemption, and cannot link the two.
- **Why POPRF and not plain VOPRF.** `info` carries the conversation and
  the day, so one long-lived server key serves every conversation and every
  day. A token for conversation X does not open conversation Y. With plain
  VOPRF that needs one key per conversation and day, and many keys make
  per-user key tagging easier to hide.
- **Server key.** One POPRF key per instance, made at random on first use
  and kept in the database (`sealed_sender_keys`, migration 0090). Its
  public half is published at `GET /api/v1/sealed/key`
  (`{"suite":"ristretto255-SHA512","key_id","public_key"}`, no session).
  `key_id` = hex of the first 16 bytes of
  `SHA-256("veritra-l2-key-v1" || public_key)`. A leaked key lets its holder
  post junk into conversations whose ids it knows; it reads nothing.
- **Epoch.** The UTC day, `e = floor(unix_seconds / 86400)`. Tokens are
  issued for `e` in {today, tomorrow} and redeemed for `e` in {yesterday,
  today} (server days), so a token fetched ahead of midnight still works
  the next day, and no token lives longer than about 72 hours. The app
  takes `e` from its own clock; the server never names it (review M1).
- **No generation (review M1, owner decision 2026-11-12).** An earlier
  draft bound a per-conversation counter, raised on each removal, into
  `info`. The server could set it per account and so split the anonymity
  set (a post made with account A's generation is A's). It is removed from
  the token, from `info`, from the routes and from migration 0090. The
  cost: a removed member's (or revoked device's) leftover tokens stay
  valid until their day ends, see "What still leaks".
- **`info`** (bytes, RFC 9497 limit 65535):

  ```text
  "veritra-l2-sealed-v1" || u16 len(conversation_id) || conversation_id
                         || u32 e                          (big-endian)
  ```
- **Token.** Input is a fresh 32-byte random `nonce`; the token is
  `(key_id, e, nonce, output)`, `output` being the 64-byte
  POPRF output. Tokens are bearer credentials kept only in the device's
  encrypted local database (schema 43).

#### Issuance (authenticated, rate-limited)

1. `GET /api/v1/sealed/conversations/{id}` (session): `{key_id,
   public_key, eligible, remaining}`. Members only. There is no epoch and
   no counter in the answer: nothing the server sends is bound into a
   token. `remaining` is `cap - (issued(t-1) + issued(t) + issued(t+1))`
   for the server's today `t`, a lower bound for either day.
2. The app (Rust, `pm_crypto_l2_token_request`) makes `n` nonces (1 to 32)
   and blinds them under `info`; it keeps the client state blob.
3. `POST /api/v1/sealed/conversations/{id}/tokens` (session, write budget)
   with `{epoch, blinded: [n × 32 bytes]}`. The server checks: switch on,
   member, conversation eligible (with the issuance gate below), epoch in
   {today, tomorrow}, and the per-account, per-conversation cap
   (`PRIVATE_MESSENGER_SEALED_TOKENS_PER_DAY`, default 200; 429
   `sealed_token_limit`). Two consecutive days are redeemable at once, so
   the cap holds for each such pair: `issued(e-1) + issued(e) + n` and
   `issued(e) + issued(e+1) + n` must both stay within it (review low c). It answers `{key_id, evaluated: [n × 32], proof
   (64)}` and adds `n` to `sealed_token_issuance(account, conversation,
   epoch)`.
4. The app (`pm_crypto_l2_token_finalize`) verifies the batch proof against
   the public key it pinned (below) and derives the outputs. A bad proof is
   refused (`PM_CRYPTO_ERROR`) and no token is kept.

Rationing is per account, not per device: the server never learns which
device redeems. The counts in `sealed_token_issuance` are deleted when they
cap nothing (epoch before yesterday).

**When the app fetches.** Not right before a send: a fetch followed seconds
later by a sealed post links the two by time. The app fetches a fixed batch
(32) for each eligible conversation on a foreground sync pass, for today and
for tomorrow, whether or not it will send. A send with no unspent token goes
identified, and the next pass refills. Volume above the batch still shows
(an account that fetches a second batch for X today sent at least 32
messages there).

**Key pinning.** The app pins the first `(key_id, public_key)` it sees per
server origin and verifies every proof against the pin. A changed key stops
sealed sending to that origin (messages go identified) until a person
accepts it in Settings. This blocks per-user key tagging after first
contact; a server that gives one account a unique key from its very first
fetch is not caught (see leaks; cross-member key gossip over MLS is the
follow-up).

#### Redemption (no session)

`POST /api/v1/sealed/messages`, on its own HTTP client with no session
token, no cookies and no shared connection pool with the session's client
(a reused TLS connection would tie the post to the session). A request that
carries an `Authorization` header or session cookie is refused (400
`sealed_request_authenticated`) so a client bug fails closed. Body:

```json
{"conversation_id", "token": {"key_id", "epoch", "nonce", "output"},
 "idempotency_key", "ciphertext", "crypto_protocol",
 "crypto_metadata", "frank_commit", "expires_at"}
```

The server checks, in order: switch on; no plaintext keys (as for every
envelope); `crypto_metadata` holds only `protocol_version`, `group_id`
(= the conversation), `content_type` = `application`, `payload_version` and
`mls_epoch`; the key is the current one; the epoch is yesterday or today
(else 409 `sealed_token_expired`); `output` equals the POPRF evaluation of
`nonce` under `info`, compared in constant time (else 403
`sealed_token_invalid`, the same answer for an unknown conversation, so the
route cannot probe ids). Then, in one transaction, in this order:

- **Double spend.** `sealed_spent_tokens(key_id, epoch, nonce)` is the
  primary key. A second use of a nonce is 409 `sealed_token_spent`, unless
  it is the retry of the same post (same conversation, idempotency key and
  bytes), which answers 200 with the stored envelope (idempotent retry).
  Spent rows outlive their envelope (an expired message is pruned, its
  nonce stays spent) and go when their epoch can no longer be redeemed.
- **Dedupe.** `UNIQUE(conversation_id, idempotency_key)` on the sealed
  envelope table; the key must be at least 128 random bits (22 to 128
  characters). A different post under a stored key is 409
  `idempotency_conflict`. This comes first, so the retry of a stored post
  answers 200 even after the conversation became ineligible.
- **Keys do not cross (review H1).** A sealed post under a key that names
  an identified envelope in the same conversation is 409
  `idempotency_conflict`, and so is an identified send under a key a
  sealed envelope there holds. Every member reads every key, so without
  this a member could post under another member's key.
- **Eligibility, then spend.** The conversation must be eligible and pass
  the issuance gate (every live device of every member reads sealed
  events), checked again here (review M2), else 409 `sealed_not_eligible`.
  That answer comes only after the two lookups above, so it proves nothing
  of either kind is stored under (conversation, key): it is the one answer
  on which the app offers the person to send the message normally
  (identified), and only on their tap (the invariant below).
- **Store and fan out.** The row in `sealed_message_envelopes` (migration
  0091) has no sender column at all. One sync event
  `message.sealed.created` goes to every member, the sender's own devices
  included, and push wakes go to every member. Retention clamps
  `expires_at` as for identified envelopes.

**Eligible conversations.** `kind` `dm` or `group`, no community or channel,
`posting_policy` `everyone`, and no member under a C5 timeout now. Each rule
the server enforces by sender cannot hold for a sealed post, so those
conversations take identified posts only (409 `sealed_not_eligible`): C2
admins-only, C5 timeouts and slow mode, C0/C7 community conversations (C7
also needs the sender for its sealed body), and messages with attachments
(`attachment_envelopes.owner_account_id` names the uploader; the app sends
any message with `attachment_refs` identified). Commits, Welcomes, key
packages, reports, receipts, typing and every admin route stay identified.

**Receive.** The app reads `message.sealed.created`, decrypts with
`pm_crypto_group_decrypt_sealed`, and takes the sender only from MLS. The
sending device cannot decrypt its own `PrivateMessage`; it recognises its
own post by the SHA-256 of the exact ciphertext it sent sealed, recorded at
encrypt time in the encrypted local table `local_sealed_own_posts`, and
commits past it (review H1: the key alone is readable by every member, so
a member's post under it was taken for the victim's own and hidden, and
re-pointed the victim's row). An own echo never overwrites a server id a
local row already holds. Blocked senders are hidden by the receiving app
only.

#### Franking a sealed message (C6 still works, owner-only proofs)

C6 v1 attributes a report through the server's authenticated sender row
(G1). A sealed row has no sender, so without a change member M could send a
sealed message whose commitment names victim S (honest receivers drop it,
as MLS says M sent it), then report it and frame S. An earlier draft fixed
this with an Ed25519 signature `s` anyone could check. The owner chose
"a leak proves nothing to anyone else" over "every report traceable"
(2026-11-12), so `s` is gone: in its place the sender adds one
designated-verifier tag per instance owner its app pinned. Only that owner
can check its tag, and that owner could have made it itself, so a tag
convinces nobody else. Built in `crypto/rust/src/l2_frank.rs` (ABI 26),
`testing/vectors/l2-frank-dv-v1.json` (checked in Rust, in Dart through
FFI, and independently in Go with `x/crypto/curve25519` and the standard
HKDF and HMAC).

**The franking key.** Every device has its own random X25519 franking
secret `f_S`, sealed in its device record (a `VFK1` section). It is not the
MLS leaf key and is never derived from the Ed25519 key. Its public key
`F_S` is listed in the account's signed L1 device list (format 2, change 7;
see `docs/designs/L1-approved-device-list.md`). Invariant: **`F_S` is the
device's fixed, listed key.** A list may set a device's key once (in its
genesis 1 or 6, its recovery version 4, or change 7, which only that device
signs and which sets only its own key from none to some), and no later
version changes or drops it while the device stays listed. A key belongs to
one device for the whole chain (enforced in Rust `check_chain`, the Dart pin
step and the server's `SeenFrankKeyElsewhere`). The record seals the key
before anything can list it (`currentFrankKey`), so a reload never makes a
second one. The test `the_franking_key_is_the_one_the_list_names` (Rust)
and the native Dart tests show the listed key equals `F_S`.

**Only while the switch is on (condition A, review 2026-11-12).** A key
makes a list version L1 format 2, which main's server and apps refuse. So
the app lists its own key in a version it signs alone (setup genesis 1,
migration genesis 6, recovery version 4, from the held seed or the typed
key) only while the server's setup status reports `sealed_sender` on; with
it off, or when the status cannot be read, the version carries no key and
is format 1, byte for byte the earlier format (`_ownFrankKeys`,
`app_state_device_list.dart`). The key is added later by change 7 on the
first sealed token pass, which runs only with the switch on. Tests:
`mobile/test/l1_app_state_lists_test.dart` (each of the four sites, off and
on, the genesis re-signed from its parsed body to the same bytes).

**Downgrade (not gated).** The `VFK1` record section is written into every
device record this build seals (`crypto/rust/src/mls/records.rs`,
`device_plaintext`), switch or not: the franking secret must be sealed
before any list could name it.
A crypto core of ABI 25 or earlier refuses such a record (trailing bytes),
so an app downgraded to such a core cannot open the device record and
loses its MLS state: it must be linked again or recovered. Never ship an
older core over a store this build wrote.

```text
pk_V  = an owner's C6 report public key (X25519, from its report seed)
Z     = X25519(f_S, pk_V) = X25519(sk_V, F_S); refused when all zero
kid   = SHA-256("veritra-frank-dv-kid-v1" || pk_V)[0..16]
K     = HKDF-SHA256(salt = "veritra-frank-dv-v1", ikm = Z,
                    info = "veritra-frank-dv-v1 key" || F_S || pk_V)
t     = HMAC-SHA256(K, "veritra-frank-dv-v1" || lp(conversation_id)
                       || lp(account_id) || lp(device_id) || kid || c)
entry = kid || t                                (48 bytes)
d     = entries sorted strictly by kid, 1 to 16 of them; empty = plain form
```

`c` is the C6 commitment. Public keys are accepted only canonical (bit 255
clear, u < p) and never at one of the low-order points; an owner key that
is refused is skipped, never fatal.

- **Send (fail safe).** The sealed token pass, never a send, loads the
  context: this device must be approved on its own verified list, and the
  list must name exactly this device's franking key (a listed device with
  no key publishes change 7 first). The owner keys are the **proof
  recipients** this app pinned (`OwnerProofPins.effective`,
  `owner_proof_pins.dart`: per owner, a key pinned for proofs on first use
  or accepted on the sealed key screen, else the D95 report pin a person
  made; owner scope, sorted by account, at most 16): the tags read these,
  never a listing, and nothing is fetched for a send. Without that context no token is handed
  out and the message goes identified. Native refuses a
  listed key other than the device's own (`pm_crypto_l2_frank_designate`).
  With no pinned owner key the message goes sealed in the plain form, which
  no one can attribute; the sealed key screen says so ("provable to no
  one", or how many owners).
- **Owner keys on first use, for proofs only (owner decisions
  2026-11-12, "auto-pin on first use" and "Keep reports manual").** The
  same token pass reads `GET /reports/inbox` for one `dm` or `group`
  conversation outside a community (`OwnerKeyWatch`,
  `owner_key_watch.dart`). The first time this device sees any owner key
  for the origin, with no proof recipient (a D95 pin counts) and no
  earlier first pin (setting `l2.owner_keys_first_pin:<origin>`, also set
  once a pin a person made while reporting is seen), it pins every listed
  key as a proof recipient without a code comparison. Proof pins are kept
  apart from the D95 report pins (setting `l2.owner_proof_pins:<origin>`:
  owner to key, or a tombstone for an owner accepted as gone); nothing in
  this flow writes `local_report_key_pins`, so a report is still sealed
  only to keys a person pinned after comparing codes, and the report
  screen still asks for that comparison. The other way round, a key a
  person pins while reporting also becomes that owner's proof recipient
  (`ReportsService.pinKeys` drops the owner's proof override, tombstone
  included). After the first pin nothing is
  pinned automatically: an owner listed with another key than its proof
  recipient (`changed`), an owner with none (`added`) and a proof recipient
  no longer listed (`missing`) are recorded (`l2.owner_keys_seen:<origin>`)
  and shown on the sealed key screen, and Settings warns, for the person
  to accept (make the listed key the proof recipient, or drop the gone
  owner from them; the D95 pins stay) or reject (nothing changes; the
  warning returns only when the server lists something else). Until they
  accept, the tags go only to the proof recipients from before, a gone
  owner included. Accept re-reads the listing and refuses if it moved
  since the screen showed it. Only `report_inbox_unavailable` reads as "no
  owner has a key"; any other error records nothing. Tests:
  `mobile/test/l2_owner_key_tofu_test.dart` (AppState, native engine),
  `l2_sealed_key_screen_test.dart`. The pass runs only while the server's
  `sealed_sender` switch is on; with it off, nothing is pinned for proofs
  on first use. Reports in both cases follow D95 (a person compares codes
  while reporting). Tests that reports stay manual after a first-use pin:
  `c6_reports_service_test.dart`, `c6_report_screens_test.dart`.
- **What the server can do before the first pin (accepted with
  first-use pinning).** It chooses when the first sight happens (it can
  answer `report_inbox_unavailable` until it is ready; meanwhile sealed
  messages go in the plain form, provable to no one) and what that
  listing holds, per account and per device (each device pins on its own;
  a second device of the same account can be shown other keys, and
  nothing compares them). That influences only **who can verify this
  device's sealed-message proofs, never who reads its reports**: reports
  are sealed only to D95 pins, which a first-use pin never writes. So it
  can:
  - **list owner keys it holds**, alone or beside the real ones. They
    become proof recipients: the holder of such a key can check a tag,
    and so learn which account sent a sealed message, but only for a
    message it is shown with its `d`. It learns no tag on its own: `d`
    travels only inside the MLS ciphertext and the report copies, and no
    report copy is sealed to a first-use key (the report screen shows the
    listed key's code and refuses until the person pins it, D95);
  - **withhold real owners.** They are not proof recipients, a sealed
    message is not provable to them (`notDesignated`), and when the server
    lists them later they wait for the person as `added`. Reporting to
    them is unaffected: it asks for the code comparison as before;
  - **list more than 16 owners** whose ids sort first, so the real owners
    fall outside the at most 16 tagged keys (reports are still sealed to
    every owner a person pinned).
  None of this is detected. After the first pin it can only raise a
  warning; what remains is a person accepting a key without comparing it
  with the owner's code, which again changes only the proof recipients.
  A device that had pinned while reporting before its first pass (D95,
  "Pinned owner keys") uses those pins as its proof recipients and never
  pins on first use; a later code comparison while reporting replaces a
  first-use proof key for that owner.
- **Wire.** Only in a payload sent sealed, `frank` may gain `d`:
  `,"frank":{"k":"<44>","d":"<64·n, standard base64 of n entries>"}}`. The
  plain form is the identified form. `P` and `c` are unchanged. The tags
  are inside the MLS ciphertext; outside it the server could test them.
  `splitFrank` reads exactly what the encoder writes (a property test
  re-encodes every accepted mutation).
- **Receive.** Commitment checks are unchanged. On a sealed message the
  plain form or a well-formed `d`; tags cannot be checked by receivers. An
  identified message carrying `d` is `invalid`. No native call, and no leaf
  key is read.
- **Report.** The reveal (schema 43) and the v2 report body keep `d` and
  the sender account; nothing else is added. The owner checks, in order:
  the context and the first-stored envelope's key (review low b); `c`
  recomputes and equals the stored commitment; its report seed is loaded
  and its own `kid` is in `d` (else **notDesignated**, with no list fetch);
  the claimed device's franking key from the claimed account's verified
  list (none: **senderUnverified**); then `pm_crypto_l2_frank_dv_verify`
  (2: **notDesignated**, 0: **proofFailed**, 1: **verified**). Framing as
  another account or device fails: the tag covers both and `Z` needs `f_S`.
- **Owner keys change: old proofs lapse.** No old report key is kept. A
  message designated to a key the owner no longer holds reads
  notDesignated for that owner; other owners still verify.

**Proof sketch** (verification (e); a sketch for the G25 reviewer, not a
machine proof). Model HKDF and HMAC as random oracles / a PRF, and assume
gap-CDH in X25519.

1. *No framing toward an honest owner V (P2).* A valid tag for `(S, V)`
   needs `K`, a function of `Z = CDH(F_S, pk_V)`. A party without `f_S` or
   `sk_V` that outputs a valid tag on a new `(conv, account, device, c)`
   either queried the oracle on `Z` (breaking gap-CDH, with the DH oracle
   answering consistency checks for other queries) or forged HMAC under an
   unknown key. `F_S` comes from S's own signed list (the server cannot
   forge it, L1), the key is fixed and unique per chain, and the tag binds
   account and device, so M's own key cannot stand in for S's.
2. *Non-transferability (P3).* `V` computes the same `K` from `sk_V` and
   `F_S`, so for every tuple the distribution of tags `V` can make equals
   the distribution S makes. A third party given `(P, kf, d)` and even `V`'s
   cooperation learns nothing it could not have got from `V` alone: the
   transcript is simulatable by `V`. A leaked `d` names `kid`s, which are
   public-key hashes, not secrets.
3. *Commitment binding.* `c` binds `P` and `kf` (C6), and the tag binds `c`,
   so a tag does not move to another message.
4. *Sealed sender (P5).* `d` is only inside the MLS ciphertext and the
   report copies (HPKE to owners), so the server sees no tag at post time.

Not covered by the sketch: side channels, a stolen owner seed (which also
lets its holder frame toward that owner, inherent to every DV scheme), and
the MLS residual below. ProVerif/Tamarin were not run (not installable in
this environment).

**What remains provable to others (accepted, owner decision 6).** Every MLS
application message is signed by the sender's leaf key over the framed
content and the group context. A member who keeps the decrypted message,
its signature and the group context (all of which its own client sees)
can hand them to anyone who trusts the binding of that leaf key to S, and
that proves authorship. A stock Veritra app keeps none of these: OpenMLS
deletes the message key once used, so a processed ciphertext row cannot be
opened again (verification (b)); no column, history export or K2 field
holds a signature over a payload (verification (c)); and a sync page that
opened a sealed message checkpoints and truncates the database log, so
the MLS state from before the message does not linger in old log frames
(verification (d); `secure_delete` already clears freed pages of the
database file). A modified app can keep them; that cannot be prevented.

- **What the verifier tells the server (accepted, owner decision
  2026-11-12).** An owner's check fetches the claimed sender's account
  device list only when `d` names that owner; the server learns, at review
  time and only from the reviewer, which account a reported sealed message
  is attributed to (the copy's id and the request's timing link the two).
  A cached list avoids the fetch. Accepted as a residual: an owner who
  reviews a sealed report tells the server which account it names.

#### What still leaks (plainly)

- **IP address and connection timing.** The sealed post comes from the same
  address as the device's session, at the moment its WebSocket is open. An
  operator who logs addresses (L2-2 turns proxy logs off by default; the
  live connection still shows them) or watches timing can usually tell who
  posted, in small conversations almost always. Sealed sender protects the
  stored record and a later database leak, not a live, watching operator.
  Tor or a VPN, plus send jitter (L2 owner question 3, default off), are
  what would help.
- **Typing and read state.** Until D60 moves them into MLS, the server-seen
  typing event (D47) names the account seconds before its post, and a
  shared read cursor can move right after it. With sealed sending on the
  app stops sending server typing in that conversation.
- **Issuance.** Who fetched tokens for which conversation and day, and how
  many. The anonymity set of a post is the members who fetched for that
  conversation and day; in a DM it is two people.
- **Key tagging at first contact.** A server can give one account a unique
  key before it ever pins one. Not detected yet.
- **Leftover tokens (review M1).** With no generation, a removed member or
  a revoked device keeps its unspent tokens until their day ends (about 72
  hours at most). Its MLS state no longer decrypts for the group, so what
  it posts is junk: receivers show it as an undecryptable or unverifiable
  placeholder. It reads nothing.
- **Day split.** The anonymity set of a post is the members who fetched
  for that day. Near midnight, and for a device whose clock is off, that
  set is split by day naturally; the server can no longer pick the split,
  but it still sees it.
- **Forced identified.** The server can answer `eligible: false` or
  `sealed_not_eligible` to any account at will. `eligible: false` makes
  that account's next messages go identified from the start. A
  `sealed_not_eligible` refusal of a sealed post never sends that post
  identified on its own (owner decision 2026-11-12, "Ask before
  re-sending"): the app would otherwise re-send it under the same
  idempotency key, which tells the server who sent the sealed post it
  chose to refuse. The message waits in the outbox, marked "couldn't send
  hidden", and the chat offers "Send normally" (the server then sees it is
  from this account, and the person is told so) or "Discard". Sealed
  sender limits what the server stores, not whether a hostile server lets
  a sender be sealed; it can still refuse, and then learns the sender of
  a post only if the person chooses to send it normally.
- **Copies after expiry (review low b).** Once the original sealed envelope
  has expired, a member can re-post its ciphertext and commitment under
  the same key, and a report about that copy verifies for the sender.
- **Sizes and counts** as before (L2-1).
- **Server rules.** C2, C5 and C7 checks need the sender, so those
  conversations stay identified; so do attachments and every commit.
- **C4 activity.** A sealed post does not mark the sender active for C4
  server succession. An active owner still self-updates each conversation
  at least every 7 days with activity, which is identified and counts.

#### Libraries

| Side | Library | Version | Licence | Notes |
|---|---|---|---|---|
| Rust (crypto core) | `voprf` (facebook/voprf) | `=0.5.0`, `default-features = false`, `ristretto255-ciphersuite` | MIT | RFC 9497 final. Brings `derive-where` (MIT OR Apache-2.0) and `displaydoc` (MIT OR Apache-2.0); `curve25519-dalek` 4, `sha2` 0.10, `elliptic-curve` 0.13 (features `hash2curve`, `voprf`) are already locked. The NCC Group review of opaque-ke (2021) covered a pre-RFC voprf; **0.5.0 itself has no published audit**. |
| Rust (crypto core) | `x25519-dalek` | `=3.0.0`, `default-features = false`, features `static_secrets`, `zeroize` | BSD-3-Clause | Owner-approved 2026-11-12 for the franking key and tags. Uses the already locked `curve25519-dalek`. No audit of 3.0.0 itself is known. The Go cross-check uses `golang.org/x/crypto/curve25519` (already a dependency). |
| Go (server) | `github.com/cloudflare/circl` | `v1.6.5` | BSD-3-Clause | `oprf` package, RFC 9497 vectors in its tests. Brings `github.com/bwesterb/go-ristretto` v1.2.4 (MIT). No published audit of the `oprf` package. |

Dart has no crypto dependency; it calls the Rust FFI. The two libraries
interoperate: a batch blinded by voprf, evaluated by circl, verifies and
finalizes in voprf to circl's `FullEvaluate` output
(`testing/vectors/l2-sealed-v1.json`).

#### ABI 26

- `pm_crypto_l2_token_request(public_key, conversation_id, epoch, count,
  out_state, out_request)`: `count` 1 to 32;
  `out_request` is `count × 32` blinded elements; `out_state` is
  `"VLT1" || u8 count || 32-byte public key || u16 len(info) || info ||
  count × (32-byte nonce || 64-byte voprf client state)`.
- `pm_crypto_l2_token_finalize(state, response, out_tokens)`: `response` is
  `count × 32` evaluated elements `|| 64-byte proof`; `out_tokens` is
  `count × (32-byte nonce || 64-byte output)`. The proof is checked against
  the key in the state.
- `pm_crypto_l2_frank_public_key(device, out_key)`: this device's 32-byte
  franking public key `F_S`.
- `pm_crypto_l2_frank_designate(device, conversation_id, commit,
  listed_key, owner_keys, out_designation)`: `owner_keys` is `n × 32`,
  `1 ≤ n ≤ 16`; `listed_key` must equal `F_S` (else refused);
  `out_designation` is `m × 48` sorted by kid, `m ≤ n`, refused owner keys
  skipped, empty (a null buffer) when none is usable. The identity is
  always the device's own.
- `pm_crypto_l2_frank_dv_verify(report_seed, sender_frank_key,
  conversation_id, account_id, device_id, commit, designation, out_result)`:
  `out_result` 1 valid, 0 mismatch (also a refused sender key or a zero
  `Z`), 2 no entry for this seed's key. The X25519 pair is derived from the
  seed inside; no call returns a private key.
- The earlier `pm_crypto_l2_frank_sign` and `pm_crypto_l2_frank_verify`
  are removed (ABI 26 amended in place; never merged).

#### Counters

Crypto ABI 26 (25 is reserved by another package; this branch goes 24 to
26), local schema 43, server migrations 0090 (keys, issuance counts, spent
tokens), 0091 (sealed envelope table, capable devices, an index on
`message_envelopes(idempotency_key)`) and 0092 (device list change 7).
The franking redesign of 2026-11-12 (owner-only proofs) amended ABI 26 and
schema 43 in place again and adds L1 list format 2. The review fixes of 2026-11-12
amended ABI 26, schema 43, 0090 and 0091 in place (none had merged): the
numbers did not change. Needs the
independent crypto review (G25) before the switch is turned on anywhere.

#### As built (2026-11-12, branch `feat/l2-sealed-sender`)

Built and tested: the Rust half (`crypto/rust/src/l2_sealed.rs`, ABI 26,
Dart bindings in `native_crypto_bindings.dart`), the Go half
(`server/internal/sealedsender`), the shared vectors
(`testing/vectors/l2-sealed-v1.json`, checked in Rust, Go and Dart), and the
server routes, storage and migrations 0090 and 0091 behind
`PRIVATE_MESSENGER_SEALED_SENDER` (off by default). Server tests cover the
double spend and its idempotent retry, wrong and relabelled epochs, a
removed member's leftover token (it still posts, review M1), the cap
across redeemable days,
ineligible conversations, a request carrying a session, forged tokens, no
sender stored or synced, expiry and pruning, and the report envelope route
for a sealed envelope.

**Older apps (built on branch `feat/l2-sealed-app`).** Apps from before
the app step treat an unknown `message.*` event as fail-closed
(`_failsClosedEvent`, `SyncFailureKind.unsupportedEvent`), so one member
holding tokens could otherwise pause the conversation (or, without scoped
sync, all sync) on every other member's device. Two server rules keep that
from happening:

- **Opt-in.** Every sync read (legacy, `?scan=bounded` and the per
  conversation route) hides `message.sealed.created` rows unless the request
  carries `?sealed=1`. They are hidden rows, not a filter after the page, so
  an older app still pages past a run of sealed posts and never sees one.
- **Issuance gate.** While the switch is on, a read with `?sealed=1`
  records its device in `sealed_capable_devices` (added to 0091, which has
  not merged). `GET /sealed/conversations/{id}` reports `eligible: false`,
  and token issuance answers 409 `sealed_not_eligible`, until every live
  device of every member is listed. So no member device that would miss a
  sealed post is in a conversation that gets tokens. Redemption checks
  the gate too (review M2), after the retry lookup: a device linked (or an
  older app installed) after tokens were issued closes it for new posts at
  once, and those go identified (below).

**App step, as built (2026-11-12, branch `feat/l2-sealed-app`, local schema
43).** Code: `mobile/lib/core/sealed_sender.dart` (token pass, key pin,
sealed post client and its retry rules), `NativeCryptoService`
(`_encryptPayload`, `processSealedApplicationMessage`, `_checkFranking`),
`AppState` (`_followServerSwitches`, the `message.sealed.created` case,
`_flushOutboxOnce`). Tests: `mobile/test/l2_sealed_app_native_test.dart`
(two native clients), `l2_sealed_app_test.dart` (a loopback server),
`l2_schema43_test.dart`, `l2_sealed_key_screen_test.dart`.

- **Switch.** Sealed sending is on only while the server's setup status
  says `sealed_sender: true` (read with each conversation list refresh).
  An app with the native crypto service sends `?sealed=1` on every sync
  read, whether or not the switch is on (off, the server records nothing).
- **Token pass.** On the foreground catch-up (at most every 10 minutes, one
  pass at a time) and when the switch turns on, for each `dm` or `group`
  conversation outside a community or channel: read
  `GET /sealed/conversations/{id}`; if it is eligible and the app holds no
  token for today, ask for `min(32, remaining)` for today and again for
  tomorrow. The per-day cap is the server's `remaining`; nothing is asked
  past it. An ineligible conversation drops its tokens. Tokens live in the
  encrypted local database (`local_sealed_tokens`, at most
  `maxSealedTokensPerConversation` per conversation), never in a backup,
  and each is taken once (oldest usable day first).
- **Key pin.** The first issuer key seen for an origin is pinned
  (`local_sealed_key_pins`, trust on first use). A different key afterwards
  is recorded as seen and stops sealed sending and token fetches for that
  origin until the person accepts it in Settings, Privacy, "Sealed sender
  key" (`features/settings/sealed_key_screen.dart`), which shows both
  fingerprints and warns what accepting risks. Tagging at first contact is
  still not detected.
- **Choice at encrypt time.** `_encryptPayload` seals a payload only when
  its type is a message type (`sealedPayloadTypes`), it has no attachments,
  the conversation is `dm` or `group`, not a shared group, carries no C7
  body, a token is held under the pinned key, and the token pass loaded a
  franking context (own listed key, pinned owner keys); otherwise the
  message goes identified, as before (a token taken without a context goes
  back). The sealed payload carries `d` to the pinned owners, or the plain
  form (`pm_crypto_l2_frank_designate`). The choice and its token are
  stored in the outbox entry with the ciphertext; the local message row
  holds no flag (the echo arrives as `message.sealed.created`).
- **Post.** `SealedPostClient` has its own `HttpClient` (no keep-alive, no
  shared connection), sends no `Authorization` header and no cookie, and
  posts `POST /sealed/messages`; `ApiClient.sendEnvelope` refuses a sealed
  envelope. Retry rules (`postSealedMessage`): a refused token
  (`sealed_token_expired`, `_token_spent`, `_token_invalid`) is replaced
  from the store and the same message posted
  again (same idempotency key and ciphertext; the outbox entry is rewritten
  with the new token first); with no token left it waits as a retryable
  503-class failure for the next token pass; 408, 429, 5xx and transport
  errors retry as other outbox entries do; a 404 (the server's switch is
  off) waits as the retryable `sealed_unavailable` (review low a); other
  4xx fail the message. **It never falls back to identified on its own.**
  A 409 `sealed_not_eligible` (the invariant below) drops the
  conversation's tokens and leaves the entry terminal under
  `terminal:409:sealed_not_eligible` (`sealedNeedsResendChoice`): the chat
  shows "couldn't send hidden" with "Send normally" and "Discard" (owner
  decision 2026-11-12). Only "Send normally" (`AppState.sendSealedNormally`,
  `reencryptSealedForResend`) has `reencryptSealedAsIdentified` encrypt the
  message afresh, identified, under the same key (new MLS ciphertext and
  franking key, no token, no `d`) and put it in the outbox entry's place
  with its failure cleared; the outbox worker then sends it once, under the
  I34 hold. It acts only while the entry still waits for the choice, so a
  second tap does nothing, and an MLS control message queued for the
  conversation (or a D68 removal hold) makes it wait and say so. Tests:
  `mobile/test/l2_sealed_resend_choice_test.dart` (no identified request
  across passes, a resume, a retry and a restart before the tap; exactly
  one after it; none after "Discard"). The plaintext for that is kept only in
  `local_sealed_own_posts` while the message is queued, never in the outbox
  JSON or on the wire. It is dropped when the entry is replaced or goes;
  the digest stays (30 days), so the echo of an earlier sealed attempt
  that lands late is still recognised as this device's own.
- **Receive.** The `message.sealed.created` case decrypts through
  `processSealedApplicationMessage` (`pm_crypto_group_decrypt_sealed`),
  which refuses identified envelopes, as the identified path refuses sealed
  ones; the server's sender fields are never read. A sealed payload must be
  a message type; any other type is `invalid`. Undecryptable posts become
  D54 placeholders after the usual retries, and a post from a removed
  sender becomes the "unverifiable" placeholder, so neither stops sync.
  The own post is recognised by the digest of its ciphertext (above); a
  decrypted sender equal to this device is refused. Messages from blocked
  senders are hidden from the timeline.
- **Franking.** `_checkFranking` accepts the plain form or a well-formed
  `d` on a sealed envelope; an identified payload with `d` is `invalid`.
  Schema 43 adds `designation` (48 to 768 bytes, whole entries, or null for
  the plain form) and `sender_account_id` to `local_frank_reveals`, and
  `frank_key` to `local_device_list_keys`; the draft's `signature` and
  `signing_key` columns are dropped where they exist. That drop also runs
  on every open at schema 43 or later (review L2): a draft of the step
  wrote version 43 on development devices, so the upgrade step never runs
  there again. It is idempotent, and a drop that removed something is
  followed by a log checkpoint (`l2_schema43_test.dart`).
- **Reports.** Report body version 2 (`report_body.dart`, 9 fields) adds
  the sender's account id and `d` (empty for the plain form), and is used
  only for sealed envelopes; version 1 is unchanged for identified ones.
  The verifier (`reports_service.dart`, `_verifySealed`) runs the order in
  "Franking a sealed message"; the claimed device's franking key comes from
  the claimed account's verified list, approved or removed
  (`DeviceListsService.frankKeyOf`). Verdicts `notDesignated` and
  `proofFailed` are new; neither is ever shown as verified.
- **Log residue.** A sync page that opened a sealed message ends with
  `PRAGMA wal_checkpoint(TRUNCATE)` (`checkpointSealedResidue`), best
  effort. Review L1: the need is written durably (setting
  `l2.sealed_residue_pending`) just before the first sealed open, the sync
  pass clears it in a `finally` too (a page that threw or returned early
  skipped its own clear), and a flag a killed app left is cleared on the
  next start's first pass. It is reset only after a checkpoint that
  truncated the log (`app_state_catch_up_followups_test.dart`).
- **Typing and read state.** In a conversation that is eligible while the
  switch is on (`SealedSender.activeIn`), the app sends no server typing
  event and only the private read cursor, and its read marker names the
  newest identified message (the server keeps no read position on a sealed
  row).

**App residuals.** A message chosen sealed is sent identified only after
`sealed_not_eligible` and the person's "Send normally", so otherwise it can
wait. Once its token is past its
day (`sealed_token_expired`) it needs a fresh one, and while the
conversation is ineligible the token pass fetches none and drops what it
held: the message stays queued as a retryable failure until a token pass
refills, the conversation is eligible again, or the person discards it.
Failing or resending the waiting message on its own is not done: after a
lost answer it may already be stored, and a resend would then show twice.
Own-post digests stay 30 days after their entry is gone. If the server
switch is turned off for good, queued sealed messages wait as
`sealed_unavailable` until the person discards them. A queued sealed
message with no fallback row (after a restore from backup, which does not
carry `local_sealed_own_posts`) waits for the choice on
`sealed_not_eligible` like any other, but "Send normally" then says it can
no longer be sent normally, and only "Copy" and "Discard" help.
`reencryptSealedForResend` is tested on its own (every branch) and through
the native re-encrypt, and the choice through AppState. The server's unread
count ignores sealed posts. A device whose list names no franking key
(any device until its first sealed token pass publishes change 7, or one
added by change 2 that has not yet published) sends identified. The
notice owner of a
sealed post is captured inside the serial receive turn, not before it.
Sealed posts get no delivery ticks (W5).

**Server residuals.** Sealed envelopes cannot be edited or deleted through
the server; `GET /conversations/{id}/messages` does not list them (devices
get them by sync and `GET /messages/{id}`, which also proves expiry), which
matters when an app falls back to that route after its sync cursor expired;
W5 receipts read only `message.envelope.created`, so sealed posts get no
delivery ticks; a sealed post does not move C4 `last_active_at`; and the
post route takes no session, so it is bounded by the token cap and the
per-address public budget, not the per-account write budget.
`push_wake_jobs` needs a sender account, so sealed wake rows name the
recipient (their block filter is then a no-op; blocking is the receiving
app's job for sealed posts).

**Invariant for the app step.** Identified envelopes are deduplicated by
(device, idempotency key) and sealed ones by (conversation, idempotency
key), so a message sent both ways is stored twice and the second copy fails
MLS at every receiver. Once a sealed attempt may have reached the server,
the app must never fall back to identified for that message: it retries
sealed under the same idempotency key (a retry of a stored post answers 200
without spending), fetching new tokens after a token refusal. The one
exception is 409 `sealed_not_eligible`, which the server answers only after
finding nothing of either kind stored under (conversation, key), in a
transaction on its single writer connection; after the person chooses
"Send normally" (never on its own: the answer could be a hostile server's
way to learn the sender), a fresh identified encrypt under the same key is
then the only copy, unless an earlier sealed attempt
the app gave up on (a timeout does not cancel it) reaches the server later,
after the conversation became eligible again. Then the sealed copy is
stored, the identified send is refused (`idempotency_conflict`, keys do
not cross), and the sealed echo, still recognised by its digest, links the
local row; the outbox entry shows as failed until the person discards it.
One copy is stored either way. The decision to seal is
made at encrypt time and stored with the outgoing message.

## Encrypted backup file (VBK2)

The encrypted backup (I45) the device uploads is one file, written by
`BackupService.createAndUpload` (`mobile/lib/crypto/backup_service.dart`). The
plaintext inside is the backup JSON (`backupFormatVersion` in
`local_store.dart`); this section is only the container. Integers are
big-endian. The key K (32 bytes), the nonce prefix N (8 bytes) and the
recovery token T (32 bytes) are random per backup; the recovery code is
`v1.<origin>.<T>.<K>` and does not change with this format.

```
header  = "VBK2" || N || u32 chunkCount || u64 plaintextSize          24 bytes
frame 0 = u32 len || seal(K, N, 0, "veritra-backup-v2-header" || T || header[0..12],
                          header[12..24])                              len = 28
frame i = u32 len || seal(K, N, i, "veritra-backup-v2" || T || header || last,
                          chunk i-1)                         i = 1..chunkCount
```

- `seal` is the existing native chunk AEAD (`attachment.rs`): AES-256-GCM
  with nonce `N || u32 index`, the index also bound in the associated data.
  No ABI change. Frame indices are distinct, so no nonce repeats under K.
- Chunks are 1 MiB except the last; `chunkCount = ceil(plaintextSize / 1 MiB)`,
  at most 64 MiB of plaintext. `last` is one byte: 1 for frame `chunkCount`,
  0 before it.
- Restore reads the header, opens frame 0 and requires its plaintext to equal
  the cleartext count and size. Frame 0 failing means the recovery code does
  not open the backup (`wrongKey`); any later failure, a mismatched count or
  size, a bad frame length or bytes after the last frame mean the file was
  changed (`corrupt`). Nothing reaches the local store until every frame,
  the last-flagged one included, has authenticated.
- Because each data frame binds the whole header and its `last` flag, a file
  cut at a chunk boundary fails whether or not its header was rewritten.
  VBK1 bound chunks only to `"veritra-backup-v1" || T` and its index, so such
  a cut restored a silent prefix.
- VBK1 files are refused (`corrupt`) (D55: no real users yet, no
  compatibility path). The upload's `crypto_metadata` stays `version: 1`
  because the server accepts only that value; the magic tells the formats
  apart.

### What the plaintext holds (backup JSON v6, D71, D73)

- **Carried:** the account (server origin, account id, username, role),
  the cached conversation list and envelopes, the decrypted history and
  reactions, pins, starred messages, conversation preferences and the K2
  history namespace. Nothing else.
- **Never carried:** the bearer token, the device secret, the session's
  device id, the sealed MLS state (the format 4 root and its
  `local_crypto_records` rows, D70), its state key, the plain and MLS
  outboxes, pending pin commands and the sync cursor. A stolen backup and
  its recovery code therefore cannot sign in, and cannot act as the device
  that made it in any MLS group. `mobile/test/backup_no_credentials_test.dart`
  scans the plaintext for each of them.
- **The old device id still appears as data.** History rows keep their
  `senderDeviceId`, and message keys are `<sender device id>:<action id>`,
  so the old device's id is in the history of the messages it sent (and
  in K2 history provenance as `source_device_id`). It only labels those
  rows: it is not a credential, and without the device secret it signs
  nothing in.
- **Restore makes no device.** It writes the history and an account-only
  session (empty token, no device), sync cursor 0 and no MLS state. Any
  root and records already on the device are deleted in the same
  transaction, so none are left or mixed
  (`mobile/test/d70_backup_records_test.dart`).
  Outgoing rows still pending are not restored: without the outboxes they
  could never be sent. Sync does not start. The device then joins the
  account as a new device. Today that means a device link from a
  signed-in device. Saving the linked
  session over the account-only one keeps the restored history when the
  server and account match; any other account drops it. The linked device
  starts fresh MLS state and publishes key packages. Its groups add it by
  reconcile (I51), and D54 placeholders cover what it cannot decrypt. A
  second restore over an account-only session is refused
  (`deviceNotEmpty`).
- **Password-only finish (D71) is not built yet.** Password sign-in needs
  the device's id and secret (`login` in `auth_handlers.go`), which a
  backup no longer has. Finishing a restore with a password alone needs
  K0's recovery-enrollment route (`docs/designs/K0-long-lived-key.md`, "All
  devices lost").
- **Older backups (v1-v5)** still restore. Their session must still bind
  to their `account_id` and `device_id`. After that check, the token,
  device secret, MLS state and key, outboxes, pending pin commands and
  cursor are dropped unread. A restore never keeps them.
- `state_counter` in the upload's `crypto_metadata` is still the device's
  MLS counter, so the server's monotonic check is unchanged. It is a
  number, not state.

## Change log since the Stage 1 freeze

The crypto surface (ABI v5, payload semantics, local schema v7) froze after
Stage 1. Every later change is listed here for the G25 reviewer.

- **L2-3 sealed sender (2026-11-12, crypto ABI 26, D122):** RFC 9497
  POPRF tokens (ristretto255-SHA512; voprf 0.5.0 in Rust, circl 1.6.5 in
  Go) let a member post to a DM or plain group without a session; the
  server stores those envelopes without a sender. Five new FFI functions
  (`pm_crypto_l2_token_request`, `_token_finalize`, `_frank_public_key`,
  `_frank_designate`, `_frank_dv_verify`); designated-verifier tags bind a
  sealed message's C6 commitment to the sender device's dedicated X25519
  franking key (listed in L1 format 2) for each instance owner the sender
  pinned, so reports still attribute it to those owners and to nobody else
  (owner decision 2026-11-12, replacing a transferable signature). The
  owners' report keys are pinned on first use as proof recipients only
  (owner decisions 2026-11-12, "auto-pin on first use" and "Keep reports
  manual"; kept apart from the D95 report pins, which still need a code
  comparison while reporting), and later changes wait for the person; an owner's review of a sealed report
  telling the server the attributed account is accepted. New
  direct dependency `x25519-dalek =3.0.0`. ABI 25 is left to
  another package. Server side behind `PRIVATE_MESSENGER_SEALED_SENDER`
  (off). The app step (local schema 43: `local_sealed_tokens`,
  `local_sealed_key_pins`, sealed columns on `local_frank_reveals`; report
  body v2; the sync opt-in `?sealed=1` and the server's issuance gate on
  sealed-capable devices, amending the unmerged 0091) is built on
  `feat/l2-sealed-app`. Schema 43 was reserved for it; C7's 41 and 42 may
  renumber at integration, and the 43 step is idempotent so it can move.
  "Sealed sender with VOPRF tokens" above has the design, what leaks and
  what is left.
- **C4 leave proof in the commit (2026-11-11, crypto ABI 24):** the
  owner-approved design, built with the review's required changes (no
  epoch field; the AAD set inside every stage attempt and checked on the
  sender's own commit; a cancelled leave self-updates; the length leak
  documented). New: `pm_crypto_c4_sign_leave`,
  `pm_crypto_group_stage_commit_proven`, commit review format 2 with the
  proven leaves, the hidden v2 payload `member_leave_signed`
  (`{"statement": base64}`, under the leave-notice mark), settings
  `c4.leave_signed.<group>.<account>` and `c4.leave_signed_out.<group>`, and
  the server's leave-notice limit raised from one to two per hour (Go, no
  migration; four per hour since round 7, so a refused leave can be retried
  at once, and the void of a cancelled leave passes the self-update
  interval, owner decision A; members drop both proofs on any commit of the
  leaver's approved leaf, see "Cancelled leave"). Vectors `testing/vectors/c4-leave-proof-v1.json` (Rust,
  Dart, Go). No local schema or server migration change. Deltas from the
  design: the epoch is gone from `LeaveTBS`, the statement and the payload;
  Dart accepts one approved proven leaf of the account (not every removed
  leaf); the committer drops statements that no longer verify instead of
  failing. Rules: "C4 leave proof in the commit". Needs the independent
  review.
- **C6 moderator keys over MLS (2026-11-11):** two hidden v2 payload types,
  `report_key` (`{"key": canonical base64 of the sender's own 32-byte report
  public key}`) and `report_key_request` (`{"accounts": [1 to 64 distinct
  account ids]}`), sent in a community's shared group, never franked (no
  `frank` member, no `frank_commit`), never expiring, never reportable
  (`FrankingPolicy.unfrankedPayloadTypes`). A receiver keeps them only in a
  group whose own MLS state holds a C4 record, only from a leaf its
  account's L1 list approves now, as settings committed in the same
  transaction as the MLS state: `c6.report_key.<group>.<account>` (the key
  the MLS sender announced; the latest in MLS order wins) and
  `c6.report_key_request.<group>` (the sync event id of the latest request
  naming this account). Requests are sent by a background pass for every
  community, never by the report flow, so they do not reveal a report
  about to be filed. A reporter seals a community report only to a
  verified moderator (C4 record) whose server-listed key equals that
  account's announced key; the manual pin is gone for moderators (owner
  keys keep D95's pin). Rules: C6 design, "Moderator keys over MLS"; §4
  type registry. No ABI, local schema or server migration change. Needs
  the independent review. Residual (review 2026-11-11, L6): both types ride
  in an open channel of the shared group, or an announcement channel for an
  owner or admin, because C0 routing (`routeEnvelope`) requires a
  `channel_id` in a shared conversation and refuses a group-level envelope
  that is not a C7 two-part body. In a community with no open channel an
  account below admin therefore has no route: a moderator's `report_key`
  and a member's `report_key_request` are not sent (`_reportKeyChannelFor`
  is null; the background pass tries again later), and reporters cannot
  seal to that moderator until an open channel exists or it is made admin. A group-level route
  would need a server exemption like the leave notice's; not built.

- **C6 private-channel reports (2026-11-11):** a report about a post in a
  private channel is sealed only to verified moderators in that channel's
  MLS roster, and the server's community inbox lists only members of the
  reported conversation. The roster (`mlsAccountsOf`, and the C3 no-admin
  roster `groupMemberAccounts`) counts only accounts with a leaf whose
  last L1 verdict on this device is `approved`, with the key in the tree
  (review L7: an unapproved leaf can carry any account's id); before a
  group's verdicts are loaded it is unknown (null: no report, no stand-in). No wire, ABI, local schema or migration change.
  Rules: C6 design, "Private channels".

- **L2-5 own-device alert (2026-11-11):** the hidden v2 payload
  `device_list_alert` (registry in "Application payload v2" §4). No ABI,
  local schema or server migration change; the receiver's alerted head is a
  local setting (`l2.alert_head.<account>`, value
  `<head>:<list id>:<alerting device>`), the
  sender's last alert per chat `l2.alert_sent.<conversation>`. The design
  said a different list id becomes `conflict`; it is held as `checking`
  instead, since a chain of another genesis is never a sticky conflict
  (owner decision 2026-11-08). Residuals: the server can drop the alert;
  an approved device of an account can hold that account's leaves in its
  chats as `checking` by alerting a head never published, until a pin shows
  that device removed (the alert then stops counting; the head carries no
  signature, so a receiver cannot check it alone); first contact is
  unchanged. Review M3 (2026-11-11): an alert counts only from a leaf whose
  verdict is `approved` (a `removed` leaf's alert is ignored); the setting
  keeps one line per alerting device, so one device's inflated head never
  drops another device's later alert; lines that no longer hold (alerting
  device removed, pin caught up, or a pin of another list id that does not
  list the alerting device: a list restarted from a new genesis) are
  dropped at the next write and never hold, so an old list's alert cannot
  hold the account's leaves as `checking` for good. While one alert holds
  an account, that account's leaves are `checking`, so their own alerts
  are not taken until it lifts (the honest device alerts again at its next
  head, which its removal of the rogue device produces). Tests:
  `mobile/test/l1_native_gate_test.dart` (alert, forged alert, hold and
  release), `mobile/test/l2_device_list_alert_payload_test.dart`. Needs the
  independent review.

- **L2-1 padding and the sealed-sender boundary: ABI 23 (2026-11-11):**
  key packages carry a zero-byte pad extension `0xF0A2` that brings them
  to a size bucket, and every staged commit that adds devices pads its
  Welcome the same way inside the encrypted GroupInfo; every leaf lists
  `0xF0A2` in its capabilities; a malformed pad is refused in added key
  packages, received Adds and Welcomes. New exports
  `pm_crypto_l2_padded_size` (the bucket rule) and
  `pm_crypto_group_decrypt_sealed` (returns the MLS-authenticated sender;
  not used by the app or server yet). `pm_crypto_group_decrypt` and every
  other signature are unchanged. Header, Dart binding (`!= 23`) and
  `scripts/verify-mobile-crypto.sh` updated; vector
  `testing/vectors/l2-padding-v1.json` (Rust, Go, Dart). ABI 23 accepts
  ABI 22 blobs (tested); the reverse is expected, not tested. No local schema or server migration.
  Rules: "L2 padding" and "Sealed sender boundary" above. Needs the
  independent review (G25), the two-stage Welcome build in particular.

- **L1 removed-sender mark (2026-11-11, local schema 40):** a message whose
  sender leaf is `removed` at receive time (on its account's list once,
  removed since, still in the MLS tree) is stored with
  `local_messages.sender_removed = 1` and shown marked "Sent from a device
  <name> removed" ("...you removed" for this account's own devices). The
  verdict is recorded at entry, because the leaf is gone once the removal
  commit lands. An edit from such a leaf marks the text it leaves; an edit
  from an approved leaf never clears a mark. History snapshots (K1, K2)
  carry `senderRemoved: true` only on marked rows, so a snapshot without one
  stays readable by an older importer. No ABI, wire or server change.
  Residual: an edit from a removed leaf whose target has not arrived yet is
  deferred unmarked; reactions carry no mark.
- **C4 app wiring and removal proofs (2026-11-11):** groups and community
  shared groups are created with the genesis role record; every commit
  producer carries `requiredRecord` (or a role command) through
  `stageCommitWithRoles`; remote commits go through the ABI 20 two-phase
  receive (stage, judge, merge or discard). New: removal proofs for
  governing accounts, an L1 gate on privileged committers, the hidden
  `member_leave` payload, and the `role_change` commit-bundle flag (server
  exempts such commits from the self-update interval). No ABI, local schema
  or server migration change. Rules: "Group role state (C4)", "C4 app
  wiring" below. Needs the independent review; not yet covered by tests.

- **C7 two-part messages, first slice (2026-11-11):** no ABI or schema
  change; behind the server's `PRIVATE_MESSENGER_C7_HISTORY` (off by
  default), which the setup status reports as `c7_history`. While it is on,
  every application message a device sends in a community conversation
  (`community_shared`, a private channel's group, or a legacy channel) is two
  parts (docs/designs/C7-channel-history.md, "Core idea"): MLS encrypts only
  the 68-byte reference `"C7R1" | body_key | sha256(sealed_body)`, and the
  envelope's `sealed_body` is `c7_seal(body_key, aad, sig | padded VAP1)`
  with `aad = lp(conversation_id) | lp(channel_id or "") |
  lp(sender_device_id) | lp(action_id)` and `sig` the post signature with
  `gen = 0` (`mobile/lib/crypto/c7_two_part.dart`). This slice always uses a
  random `body_key`, the `members_from_join` behaviour, so a newcomer can
  open nothing from before its join; generation keys, records and
  `history_sync` (the `full` mode) are not built. A receiver that decrypts a
  reference checks the body's hash and opens it under the reference's key;
  a missing or bad body is a P1 `invalid` row and the MLS state and cursor
  commit. Receiving two-part messages needs no switch. The sealed body is
  kept in the outbox entry, so a retry is byte-identical, and the server's
  replay check compares it. With C7 off nothing changes on the wire.
- **L1 complete adds, join notice, recovery retype and pre-L1 RK
  confirmation (2026-11-11):** held groups the server reports no change
  for are audited against signed lists (bounded, after the reconcile
  fallback). Accounts with an approved device left out for an hour are
  shown in the chat, and the clock persists in settings. A recovered device
  with no usable held seed signs change 4 from the retyped key through the
  same native call. A pre-L1 key is confirmed by `rk_id` and set again with
  change 5. No ABI, schema, migration or dependency change. Design:
  [`L1-approved-devices.md`](designs/L1-approved-devices.md). Not yet
  covered by tests; needs the independent review.

- **L1 signed-list add discovery (2026-11-11):** creation and reported pending
  membership changes derive device candidates from verified account lists,
  subtract the native roster and claim explicit IDs. Claim answers must be a
  unique subset of the requested account/device pairs; the native gate still
  enforces the pinned signing key. Entirely withheld pending conversations and
  the incomplete-join notice remain open. Design:
  [`L1-approved-devices.md`](designs/L1-approved-devices.md). No counter changes.

- **L1 enrollment-anchor review follow-up (2026-11-11):** journal locally
  signed genesis or authenticated linked-device chains before durable session
  activation. Replay before foreground/background restore can activate MLS.
  Link chains must prove the exact frozen approver signed the new key's add
  before any pin is written. Storage and validation failures stop activation;
  the pending claim/journal survives for retry. See
  [`L1-approved-devices.md`](designs/L1-approved-devices.md).

- **L1 chain-import continuity review (2026-11-11):** a verified imported
  chain must contain the exact existing pinned head before it can advance
  that pin. An unrelated genesis or a signed fork cannot replace trust via
  `pinChain`; conflicts remain sticky and identical imports are no-ops.
  Native regressions cover replacement, forks, rollback and valid extension.
  No ABI, schema, migration or release-gate change. The full package remains
  incomplete, including durable enrollment anchors; see
  [`review evidence`](../testing/evidence/L1-review.md).

- **L1 local genesis anchor (2026-11-11):** setup and invitation registration
  pin their locally signed genesis without consulting the server first.
  Withholding the list or returning a failed read cannot discard this trust
  anchor and enable a later server-supplied genesis. Legacy accounts with no
  locally signed genesis retain the reviewed migration flow. No ABI, schema,
  migration or release-gate change. Design:
  [`L1-approved-devices.md`](designs/L1-approved-devices.md).

- **L1 bounded long-chain verification (2026-11-11):** client downloads now
  allow up to 4,096 statements, independently of the native 256-statement batch
  limit. First contact, chain import and fork proof verification compose the
  existing native chain and step verifiers with full pair history. Pinned
  catch-up can cross 256 versions. Download and native history limits still
  fail closed; no counter, dependency or release-gate change. Design:
  [`L1-approved-devices.md`](designs/L1-approved-devices.md).

- **L1 current-list integration (2026-11-10):** design:
  [`L1-approved-devices.md`](designs/L1-approved-devices.md). Reuses the already
  merged Rust, server and mobile L1 implementation. Rejudges previously approved
  leaves before sending and when judging incoming senders, using the existing
  bounded/rate-limited list refresh. A verified signed removal holds outgoing
  encryption until the leaf leaves the MLS tree. Cached approval cannot override
  a newer pin or signed fork. Incoming formerly approved senders retain the
  existing `removed` policy. No ABI, schema or migration change is needed;
  assigned counters 24/41/0074 remain unused. Full-package follow-ups are recorded
  in the integration design; independent security review is still required.

- **C3 key freshness, local schema 35 (2026-11-11):** no ABI or wire change.
  The info key a device seals with (`CommunityInfoService.currentKey`) was
  the one whose id first arrived here last. A retired key whose first copy
  arrived after its replacement (a delayed message, or a past-epoch message
  MLS still decrypts) therefore became current, and later edits were sealed
  under a key the removed member holds. The rule is now:
  1. Every stored `info_key` row carries `epoch`: the MLS epoch the message
     was encrypted in, read from the PrivateMessage header **after** it
     decrypted (the epoch picks the epoch secrets and is in the content
     AAD, so decryption authenticates it). The server's `mls_epoch` hint is
     never used. A device's own sent copy carries the epoch it encrypted in;
     a key it makes carries `max(group epoch, last removal epoch)`.
  2. A repeated row keeps its first arrival (`seq`) and the **lowest** epoch
     seen for it, so a delayed original lowers it and a re-delivery in a
     later epoch never raises it. Evicted keys keep the epoch with their
     tombstone.
  3. Only trusted rows count: in the owning group, from this account or
     from an owner/admin under the verified role state. A key's freshness is
     the lowest epoch of its trusted rows; a current member replaying a key
     at an old epoch it kept secrets for cannot retire it. In a private
     channel's group only, when no such key is fresh, rows from verified
     moderators are trusted as a second choice (owner decision 2026-11-11:
     a moderator member rotates when no owner or admin is a member; see
     the C3 design, "Remote removals: who rotates"). Owner and admin keys
     always win over a moderator's, and an owner or admin member that finds
     only a moderator's key current mints its own (owner decision B,
     2026-11-11; `replaceModeratorKey`).
  4. A key whose freshness is below the group's last removal epoch (the
     watermark committed with the MLS state) is retired: never current, even
     when it is the only key held. Callers then ask, or wait for rotation.
  5. Among the rest the freshest wins; equal epochs fall back to the key whose
     id first arrived last (the previous rule).
  Residuals: an owner/admin can still make any key current by sending it in a
  fresh epoch (it is trusted to choose keys; honest code never re-sends a key
  from before a removal it has seen). In a private channel a verified
  moderator can likewise make a key it never sent before current, but only
  as second choice: while no owner or admin key is fresh. In that second
  choice a key is also retired when any row of it in the group, from any
  sender, trusted or not, has an epoch below the last removal. Counting only
  rows from currently trusted senders was not enough (review 2026-11-11): an
  admin mints K at epoch 5, a removal lands at 10, the admin is demoted, a
  moderator re-sends K at 12, and K's only trusted row was the moderator's,
  so K was current again. The primary owner/admin path keeps trusted rows
  only, so a member cannot retire the admins' key by replaying it at an old
  epoch; in the second choice it can (it holds old epoch secrets for a
  couple of epochs), which only leaves the channel without a current key
  until a rotation (fail closed). Test: `c3_community_info_service_test.dart`
  ("demoted since"). Rows stored before schema 35 have no
  epoch and rank below every key with one and below any removal. A device
  upgraded with a removal already recorded for a group and only such rows
  therefore has no current key there; no admin can answer its request (their
  keys are epoch-less too) and no rotation is due, so it stays without one
  until the next removal rotates. There is no release: recreate such demo
  communities. Schema 35 adds the nullable column only (idempotent
  `ALTER TABLE`). Evidence:
  [`C3-key-freshness-2026-11-11.md`](../testing/evidence/C3-key-freshness-2026-11-11.md).

- **C3 remote-removal dedup (2026-11-11, owner decision):** no ABI,
  schema or wire change. Only owners and admins under the verified C4 record
  rotate info keys (a moderator never does; the server's role is used only
  without a record). A device that did not make the removal waits 15 s +
  30 s per rank + a device jitter (rank from a SHA-256 order of the verified
  owner and admins per key home and removal epoch, capped at 8), counted
  from the later of observation and session start. An obligation ends
  without a new key when the current fresh key was delivered by another
  device of a verified owner or admin; this device's own stored copies and
  moderators' keys never count. Non-admins then complete too. The schedule
  only changes timing; it cannot end an obligation. See the C3 design,
  "Remote removals: who rotates".

- **C3 remote-removal obligations (2026-11-11):** no ABI, schema or wire
  change. The remote commit path uses ABI 13's authenticated removal outcome
  and wipes its unused exporter root. Surviving devices persist the removal
  epoch in encrypted local metadata atomically with MLS state and cursor.
  Foreground community refresh maps that obligation to the shared or private
  info key home. Inbound-only wakes record it without sending. Publication,
  key answers and add delivery refuse stale keys until rotation completes;
  a newer epoch cancels an in-flight rotation. The completion watermark is
  separate from the native removal watermark, so a crash or overlapping
  removal cannot acknowledge an obligation that was never completed.
  Verified C4 role integration remains unfinished; this does not complete C3.

- **C3 add-key delivery and overlapping removals (2026-11-11):** no ABI,
  schema or wire change. After merging its accepted add bundle, the committing
  device sends the current info key into its owning group and re-announces
  accepted records under that key where the verified editor policy permits it.
  Foreground sync completing an own bundle after a lost response also triggers
  delivery. The normal send queue and removal holds apply; request/answer
  remains the recovery path for interrupted delivery and inbound-only wakes.
  A newer removal token cancels an older rotation before further re-sealing
  and clears its retry delay. Production C4 role wiring remains unfinished.

- **C3 senders and fetch loop (2026-11-09):** no ABI, payload or schema
  change. The `info_key`, `info_key_request` and `info_update` types are now
  sent: through the ordinary send path (removal holds apply), unfranked, no
  expiry, a hidden action row, and the sender's own copy kept in the same
  transaction (the outgoing transition gained `communityInfo`). A device's
  own new keys are written locally outside any MLS commit. Rotation marks
  are a setting. Design: C3, "Built 2026-11-09". The local port also fences
  API results and sends to their session, refreshes the captured token after
  reauthentication, checks cached keys' owning conversation, and prevents a
  late cache read from rolling back the displayed revision. It retries
  unqueued key requests/answers and batches the versions query beyond 200
  channels. [Local verification and remaining work](../testing/evidence/C3-rest-2026-11-09.md).

- **B6, group-call media keys: ABI 22 (2026-11-11):** one new call and one
  new signing domain, for [`B6-group-calls.md`](designs/B6-group-calls.md)
  (S2). `pm_crypto_group_b6_media_key(handle, group_id, call_id, account_id, device_id, stream)`
  returns (the sender leaf is found from its identity; a device in no leaf or in two refuses) `K(s,t) = HKDF-SHA256(salt "veritra-b6-sender-v1", ikm =
  MLS-Exporter("veritra-b6-media-v1", lp(call_id) | u64(epoch), 32),
  info = u32(leaf) | u8(stream))` for the group's current epoch (stream 0
  voice, 1 camera, 2 screen, 3 screen audio). The exporter secret never
  leaves the core. **This is the one exception to C7's rule that no
  stand-alone exporter output leaves the core**: the keys must reach
  libwebrtc's frame cryptor. Only `K(s,t)` leaves, for the one label, and a
  leaf that is not in the group is refused. `pm_crypto_c7_sign` and `_verify`
  also accept the domain `veritra-b6-join-v1` (message
  `lp(group_id) | lp(nonce) | u64(expires_at) | sha256(key_package)`); no
  signing domain is a prefix of another (tested), so a join signature is never
  a valid MLS, C7, invite or L1 signature. Vector
  `testing/vectors/b6-media-v1.json`, checked by Rust and Go
  (`server/internal/b6vector`); the Dart check and binding come with S5. The
  number is the next free one above integ (renumbered from the first assignment, 28). Needs the independent
  crypto review before release (design S2). Not built yet: the call-group
  context extension check. **For the reviewer:** the core does not know
  which groups are call groups, so the call accepts any stored group id,
  a persistent conversation group included. The label keeps the output
  separate from every other exporter value, but the exception is wider than
  "call groups only" until the context extension marks call groups and the
  call refuses the rest. A call group also lives in the same device
  provider as the conversations, so a seal while a call is open would write
  it into sealed state (D70); the app must not wire rooms to the messaging
  device until the core keeps call groups out of seals (design, "Not
  built").
- **C3, encrypted community info: records, payloads, local schema 31
  (2026-11-08):** no ABI change. Design
  [`C3-private-channels-and-info.md`](designs/C3-private-channels-and-info.md),
  "Build status". Records for `community`, `category` and `channel` reuse
  W11's `VPR1`/`VPE1` framing, chunk AEAD and context literal
  (`community_info_codec.dart`); a record takes the smallest bucket it fits
  (deviation, see the design). Three hidden v2 payload types `info_key`,
  `info_key_request` and `info_update` (§4) are registered and stored on
  receive in the MLS commit's transaction; they are never franked, and a
  receiver keeps no reveal for them even when one is, so a report can never
  hand an info key to its reader. Local schema 31 adds `local_info_events`
  (keys, announcements, key requests; bounded 4/8/16 per subject) and
  `local_info_records` (accepted records). Neither goes into a backup, a
  history snapshot or a K2 transfer; a restore clears them and the device
  asks again. Receive rule (`community_info_book.dart`): a record is shown
  only when an `info_update` from an allowed editor under the community's C4
  role state, sent in the group that owns the key, names its exact SHA-256,
  revision and key id, and the key came from that same group. Rows are kept
  per sender and group, only from community conversations; a key an
  accepted record uses is never evicted, and no key is dropped because a
  record fails to open (its id is a hash of the key). Server
  migration 0063 binds app-chosen category IDs to communities. Senders,
  fetches and screens are not wired yet.

- **C4, group role record carrier, ABI 20 (2026-11-08, D80, D81, D86):**
  design [`C4-custom-roles.md`](designs/C4-custom-roles.md), items 1 to 5;
  rules and formats in "Group role state (C4)" below. The header, the Rust
  constant, the Dart binding and `scripts/verify-mobile-crypto.sh` pin ABI
  20. **Nothing is wired into the app yet**: no group is created with a
  record, no producer carries one and the receive path still uses the
  one-shot call. **Needs the independent crypto review before release.**
  Code: `crypto/rust/src/mls/c4.rs` (tests `c4_tests.rs`),
  `crypto/rust/src/ffi/c4_calls.rs` (tests `ffi/c4_tests.rs`),
  `mobile/lib/crypto/c4_roles.dart` (test
  `mobile/test/c4_roles_native_test.dart`, which runs the real rules engine
  against the real library).
  - **Capability (item 1).** Every key package and every creator leaf lists
    GroupContext extension `0xF0C4` in its capabilities (OpenMLS's defaults
    otherwise). A record group lists it in its required capabilities, so an
    ABI 19 key package cannot be added to one (refused at staging). The
    server's structural check already accepted unknown capability values;
    `server/internal/mlswire` gains a real ABI 20 fixture and tests, and the
    publish route takes it. Groups made before ABI 20 have no record and are
    recreated, not migrated (C0).
  - **New symbols.** `pm_crypto_group_create_with_roles` (item 2),
    `pm_crypto_group_stage_commit_with_roles` (item 3),
    `pm_crypto_group_stage_incoming_commit`,
    `pm_crypto_group_merge_incoming_commit`,
    `pm_crypto_group_discard_incoming_commit` (item 4) and
    `pm_crypto_group_role_state` (item 5).
  - **Behaviour change (fail closed).** `inspect_commit` still refuses every
    proposal type but Add, Remove and Update on the one-shot calls
    (`pm_crypto_group_process_commit` and its C7 and L1 forms): a commit
    carrying a GroupContextExtensions proposal is `PM_CRYPTO_ERROR` there and
    is only ever merged through the two-phase calls, after Dart judged it.
    Consequence for wiring: producers that carry records must land **with**
    the two-phase receive path, not before it, or every receiver still on
    the one-shot call stops syncing at the first record commit.
  - **Held commits.** The staged remote commit is held in memory per group
    (never sealed, gone after a restore), bound to the epoch authenticator
    it was staged on and to the SHA-256 of its bytes. Deleting the group,
    a join, a one-shot process and merging an own commit forget it; staging
    again replaces it. OpenMLS persists the commit's handshake ratchet step
    when it stages a PrivateMessage, so the same bytes stage only once per
    sealed state: after a discard the app restores its committed state and
    never seals (as after any refused commit today).
  - **Not covered by Rust.** Whether a record change is allowed (that is
    `validateCommit`), whether a removal was allowed (C1/C5), and the record
    codec. Device ids in the review are raw bytes, as in L1: a member can add
    an identity that is not UTF-8, and a record can only name UTF-8
    accounts, so such a commit cannot pass `validateCommit` (the Dart review
    getters answer null; the caller refuses).

- **L1-3, device-link commit-then-reveal, ABI 18 (2026-11-07, D100 A;
  TASK-010, TASK-048):** design
  [`L1-3-link-commitment.md`](designs/L1-3-link-commitment.md). Protocol
  `veritra-device-link-v4` on the K2 route. The existing device commits to a
  fresh 32-byte random at create (`source_commitment`). The new device adds
  its own random to the claim (`recipient_random`, a native output). The
  existing device reveals its random only after its native accept of the
  claim is committed, and the new device opens the commitment, read only,
  before it shows the 8-digit SAS. A relay holding the QR secret therefore
  gets one 10^-8 guess per run. The approval tag still covers only the claim
  transcript, which carries the commitment, so the frozen pending state never
  needs the reveal. **ABI 18 is not backward compatible:** the K2 control
  context gains two fields; `receive_begin` returns no SAS; `source_accept`
  takes the source random; `inspect` reports `has_sas`; there are new ops
  12 `reveal_sas` and 13 `source_commitment`; and
  `pm_crypto_device_link_transcript_hash` (v2) is removed. Native transfer
  records move to item version 2. Version-1 (v3) records are dropped on load,
  never refused. A history copy in flight across the upgrade cannot finish: its
  progress row keeps retrying until it expires (at most 7 days) and the device
  links again (demo data only; mapping the missing record to an abandoned
  copy is a follow-up). Server migration 0060 adds four write-once columns,
  revokes pending and claimed links that have no commitment, adds `POST
  .../v3/{id}/reveal` (source only) and refuses approval before the reveal
  (`409 reveal_required`). The source's session-only reveal and approve
  routes move from the credential budget to the signed-in budget, exact clean
  spelling only. The history transfer keeps its
  `veritra-device-link-v3` label. Vector `testing/vectors/device-link-v4.json`
  (independent Python, checked by Rust). No MLS group, payload or local schema
  change. Open: the server's legacy v2 link routes still exist but no client
  can speak v2. Remove them after L1 lands. **Needs the independent crypto
  review before release.**
- **L1-3, approved-device list, mobile (2026-11-07, D94, D100):** local
  schema 26 (21 to 25 were reserved for other packages; owner, 2026-11-08:
  once 26 lands the next free local schema is 27, because an upgrade step
  gated below 26 never runs on a device already at 26); no ABI, payload or
  server change. Design: [`L1-approved-device-list.md`](designs/L1-approved-device-list.md).
  - **Pins.** `local_device_list_heads`, `_keys`, `_conflicts` and
    `local_approval_leaves` (never in a backup, cleared with the identity).
    `DeviceListPins` (`mobile/lib/core/device_lists.dart`) pins a chain on
    first sight (whole chain verified in Rust), then moves only forward with
    `device_list_check_step`; it re-reads the pinned head on every refresh, so
    another statement at the pinned version is checked as a whole chain and,
    if it verifies and grows from the pinned version 1, becomes a sticky
    conflict with both statements kept. A chain from another version 1 (one
    the server alone could make up) leaves the pin as it is and is never
    sticky (owner, 2026-11-08). A
    lower head, a gap or a bad step is "unavailable" and changes nothing.
    Refreshes are rate-limited to one a minute per account, and an own
    `device_list.updated` event clears the limit.
  - **The add gate (TASK-006).** Every staged add (conversation creation,
    reconcile, re-adds) uses change list version 2 with the signing key the
    pin lists for that device, never one the server sent; Rust refuses a key
    package with another key. A device not approved now is neither claimed nor
    staged (`DeviceListNotApprovedException`, the change stays pending with
    the TASK-029 backoff). Without pins nothing is added (fail closed).
  - **Receiving.** A commit or Welcome is applied as before, never refused for
    an L1 reason. Every leaf of the group (`pm_crypto_group_members`) is then
    judged (`approved`, `removed`, `unapproved`, `checking`) and the verdicts
    commit in the same transaction as the group state. A Welcome's roster is
    also checked against the conversation's participants. Judging waits at
    most 10 s per leaf and 15 s per group for the server, then reads only the
    stored pins.
  - **The approval hold.** While any leaf is not `approved`, the conversation
    encrypts nothing (messages, call signals, self-updates:
    `ConversationApprovalHeldException`); a removal commit is still allowed.
    The hold lifts only on local evidence: a commit that removes the leaf, or
    a refreshed pin that approves it. A group with no rows (from before L1, or
    rows lost after an own commit) is judged before it is next used.
  - **Message verdicts.** A message from a leaf that is not `approved` or
    `removed` is replaced by an `unapproved:` placeholder; its text is not
    stored. This includes a sender still "checking" after a fresh judgment
    (owner left it to the implementer, 2026-11-08: fail closed rather than
    keep text from a device no list approves). A `removed` leaf's messages are shown (not yet marked).
  - **Signing.** Genesis at setup and registration; change 2 at K2 link
    approval, built from the transcript the native K2 state verified (claim
    tag and typed code) and only after the approval request exists, so never
    before both checks (TASK-010/048 condition); change 3 at revoke and as a
    repair for siblings the server shows revoked; change 5 at recovery-key
    set and replace (`rk_list_pub`); the recovery seed is held at a K0-R claim
    and change 4 is posted at completion, before key packages; change 6 (the
    migration genesis) from Settings after the user ticks their devices. Every
    signed version is re-signed on a 409 `device_list_conflict`, up to 3 times.
  - **Not built yet (follow-ups):** the retype fallback when no recovery seed
    is held and the confirmation of a pre-L1 recovery key (both need a
    screen); complete adds (staging every approved device that is not a leaf,
    not only the ones the server lists); the "removed" mark on messages; the
    per-conversation state lines ("Checking <name>'s devices"); the new
    device's anchor only logs a mismatch. Change list version 1 is still
    accepted by Rust; nothing in the app sends it any more.
  - **Server key-package gate (bug-hunt Q-1; owner 2026-11-08, replacing
    D100 check 02's "no server check").** For an account with a list, the
    server refuses a published key package whose leaf signature key
    (`mlswire.LeafSignatureKey`) is not the key the head names for the device
    (400 `key_package_not_listed`) and claims only packages that carry it,
    deleting stored ones that do not. No migration. An honest-server gate:
    clients still stage every add with their own pinned key.
  - **TASK-010 and TASK-048 (commit-then-reveal and key commitment in device
    linking, D100 A):** built in their own change (see its entry); this step
    only signs change 2 after the link checks.
  - **Independent review fixes:** change 2 names the pair whose v3
    transcript hash, recomputed in Dart (`k2_transcript.dart`, the
    `link_v3.rs` vector), equals the one native verified; before, the
    re-fetched record's key was signed, and a server could swap it. Every
    judgment knows the participants, so a re-judge by list alone no longer
    undoes the Welcome's roster check. A pin that does not approve a pair a
    decision needs is fetched again past the one-minute limit (at most every
    5 s per account), and a sender with no row or an unapproved row is judged
    again before its text is dropped, so a device linked within a minute of
    the last fetch is not hidden for good. The signed change 4 is stored and
    posted again until the server takes it. Setup and registration pin their
    own genesis. Call signals from a leaf that is not approved are dropped.
  - **Known gaps after review (historical):** the cached-approved-leaf gap is
    fixed by the 2026-11-10 current-list integration above. A conflict is sticky with
    no clear path, and a made-up genesis from the server alone triggers it;
    text from a `checking` sender is dropped, not kept hidden (owner
    question); judging a commit can wait about 25 s for the server inside
    the crypto queue, more than a 20 s background wake. The first-sight
    256-version limit is replaced by bounded native-step composition in the
    2026-11-11 entry above.

- **L1-1, approved-device list, crypto layer, ABI 14 (2026-11-07, D94):**
  design [`L1-approved-device-list.md`](designs/L1-approved-device-list.md).
  Additive except for one call (`pm_crypto_recovery_key_derive` gains the
  output `out_rk_list_pub`); the header and the Dart binding pin ABI 14
  exactly. **Nothing is wired into the app, the server or the schema**, no
  local schema or migration changes, no new crate. **Every piece below needs
  the Opus review and the independent crypto review the design asks for
  before release; neither has been done.** Code: `crypto/rust/src/l1.rs`,
  `mls/list.rs`, `ffi/l1_calls.rs`, `mls.rs`, `recovery.rs`; Dart:
  `mobile/lib/crypto/l1_device_list.dart`. Vector:
  `testing/vectors/l1-device-list-v1.json` (Rust and the Go test
  `server/internal/httpapi/vdl1_vector_test.go`, an independent
  test-only reimplementation, check all of it; Dart checks the statements
  through the native calls).
  - **Format and rules (VDL1).** Exactly as the design: body, statement,
    `list_hash`, the signed message under `veritra-l1-device-list-sig-v1`
    (disjoint from every other Veritra label, tested), the "Who may sign
    what" table, strict parsing (one canonical spelling, 4 KiB, 1 to 16
    sorted entries). Signatures are `verify_strict`. A listed signing key or
    recovery key must be a canonical, valid, non-small-order Ed25519 point
    (refused as malformed): a key the strict verifier would refuse can never
    sign for its device. Failures are four kinds, checked in this order:
    malformed (`-11`), chain (`-13`), rule (`-14`), signature (`-12`), so a
    statement with one fault reports it; the vector pins 76 single-fault
    refusals and 2 whole-chain refusals.
  - **The verifier is bound to the account asked about (review fix).**
    `pm_crypto_l1_check_step` and `pm_crypto_l1_check_chain` take a required
    `expected_account_id` (1 to 128 bytes; empty or longer is
    `PM_CRYPTO_INVALID_ARGUMENT`) and refuse a statement or chain of any other
    account as chain (`-13`), a genesis and a migration genesis included, as
    the very first check. Without it a server could answer a fetch for
    account A with a real, validly signed chain of account B (devices it
    controls), and any missed account comparison in the caller would have
    bypassed the trust anchor. It went in before ABI 14 shipped, so there is
    no ABI 15. The vector gains `expected_account_id` on every refusal,
    four "another account" refusals and `refused_chains` ("chain of another
    account"), checked by Rust, Go and Dart; each valid chain also states its
    `account_id`.
  - **Ids are bytes, and nothing fails after a merge (review fix, D94).**
    Rust reads an id out of an MLS credential as 1 to 128 arbitrary bytes, so
    a member can commit an Add whose device or account id is not UTF-8. The
    commit is merged by the time the pairs come back, so a Dart decode that
    throws would stall sync. Dart now carries every account and device id as
    bytes (`LeafPair`, `DeviceListPair`, the summaries, `DeviceListBody`,
    keyed membership changes, so a bad leaf can also be removed by its
    bytes), and `CommitPairs` never throws: a buffer it cannot read is
    `unreadable` (judge nothing, hold the conversation). In Rust the pair
    buffers are encoded inside `commit_outcome`, before the merge, on both the
    process and the merge paths (C7's ABI 13 calls share it), so an encoding
    failure refuses the commit with the group untouched and the FFI no longer
    has an `unwrap_or_default` after the state changed.
  - **Where this extends the design.** (1) The no-return and
    one-key-one-device rules over the whole chain are enforced in Rust:
    `pm_crypto_l1_check_step` takes a `history` of every pair listed before
    (the app's keys table; `prev`'s entries count automatically) and
    `pm_crypto_l1_check_chain` builds it itself. The design left these to
    Dart; with Rust holding them the vector can state the violations and Dart
    cannot forget them. Passing an empty history checks only against `prev`
    (a device removed earlier would not be caught), so L1-3 must pass its
    table. (2) A recovery-key change (change 5) must actually change the
    recovery key. (3) Key validity at parse, above.
  - **Signing.** A device signs through `pm_crypto_c7_sign` with the L1 label
    as `domain`, as the design says (one credential-key sign entry point).
    The L1 label is not in the C7 domain list and `pm_crypto_c7_verify`
    refuses it, so raw bytes can never be signed or verified under it. For
    that label `message` is a body, not signed bytes: Rust parses it
    strictly, requires this device's own account, requires a genesis to name
    exactly this device with its own key and a migration genesis to include
    it, refuses a recovery version, and signs
    `label | SHA-256(body) | 0x01 | lp(own device id)` itself. The other
    rules need the previous version and are checked by `check_step` before
    a version is used.
  - **Recovery signer (D94 default: the seed stays on the waiting phone).**
    `rk_list_pub` joins the derive output (HKDF label `veritra-k0
    device-list`; not the K0-R claim key). `pm_crypto_l1_recovery_hold`
    derives the seed from typed entropy and keeps only the seed in the device
    record as a tagged section after the transfers (`"VL1H" | 1 | seed`);
    `_hold_public` reads its public key, `_hold_drop` forgets it,
    `pm_crypto_l1_sign_recovery` signs change 4 from the held seed (dropped
    once used) or from typed entropy (the retype fallback, nothing kept). It
    signs only for a change-4 body naming this device alone with its own key,
    and only a statement that passes `check_step` against the head at
    completion and the history, so no signature is made for a version the
    chain would refuse (the head's recovery key not being this seed's
    included). A record without a seed is byte for byte what ABI 13 wrote; a
    record with one is refused by ABI 13 (its transfer decoder rejects
    trailing bytes), tested. The legacy format 3 seal refuses to drop a held
    seed.
  - **Adds carry the expected key.** Change list version 2 puts the 32-byte
    signature key after each add's device id; `stage_membership_commit`
    refuses a key package whose leaf signature key differs and stages
    nothing. Version 1 is still accepted, because nothing sends version 2
    yet; L1-3 moves every sender to version 2, after which version 1 should
    be refused (a later ABI step).
  - **Leaves, committer and added pairs.** `pm_crypto_group_members` returns
    every leaf's `(account, device, signature key)`.
    `pm_crypto_group_l1_process_commit` and
    `pm_crypto_group_l1_merge_pending_commit` are the C7 commit calls plus
    two outputs: the pairs of the commit's Add proposals and the committer's
    pair, read from the staged commit and tree. The commit is never refused
    for an L1 reason (D94 apply-then-hold): the app judges the pairs and
    holds the conversation. The refusal of a changed leaf signature key,
    which L1 needs, landed with C7 in ABI 13 (`inspect_commit`,
    `c7_an_update_that_changes_the_signature_key_is_refused`).
  - **Bug-hunt tasks.** TASK-006 (authorize committers, inviters and
    identity-key bindings): the crypto layer now supplies the trust anchor
    check, the committer and added pairs, the roster of a joined group, the
    expected key on adds and the changed-key refusal; it deliberately does
    not refuse in `process_commit` or `join_group` for an L1 reason (D94), so
    the task closes with L1-3, which judges the pairs against the pins and
    holds. TASK-010 and TASK-048 (SAS commit-then-reveal): built with L1-3
    (D100, ABI 18, [design](designs/L1-3-link-commitment.md)); see the L1-3
    change-log entry. L1-3 must sign change 2 only after the claim tag and
    the typed code verify, which under v4 also means after the reveal.
  - **Remains for L1-3 (mobile)** and the other steps: pins and the keys
    table (local schema), fetch and verify, the add gate and complete adds,
    judging commits and Welcomes against the pins (and a Welcome roster
    against the conversation's participants), the approval hold and message
    verdicts, the own-account audit, genesis at setup and register, signing
    at link approval (v2, v3) and on the new device's anchor, revoke, repair,
    key set and replace, the recovery hold at claim and the change-4 post (or
    the retype), migration genesis with review, confirmation of pre-L1 keys,
    the one-time group audit, strings; L1-2 (server) owns the migration,
    routes and honest-server gates.

- **C6 D95, sealed envelope id, per-owner copies, local schema 19
  (2026-11-07):** no ABI or payload change. Local schema 19 (C6 only) adds
  `local_frank_reveals` (the franking key `kf` and the exact bytes `P` of a
  received franked message, with the envelope id) and `local_report_key_pins`
  (the instance owners' pinned report keys). The report aad is now v2 (report
  id instead of envelope id, vector `testing/vectors/c6-report-aad-v2.json`),
  the report body (with the envelope id) is sealed inside the report, one copy
  per instance owner, and the server never learns which message a report is
  about. Migration 0047 changed in place (it was not yet merged). Details in
  [Franking v1](#franking-v1-c6), "D95".
- **Sender expiry in the payload (TASK-106, 2026-11-07):** a `v: 2` payload
  may carry a top-level `expires_at` (epoch milliseconds, a positive integer
  below year 9999; anything else reads as absent). The sender sets it from
  the conversation's disappearing timer; MLS authenticates it, and the
  franking commitment covers it. A receiver stores the **shorter** of it and
  the server-stamped envelope time and ignores a longer server time. The
  sender's own copy starts with it, and its first echo can only shorten it.
  A payload with no `expires_at` (an older sender, or no timer) falls back to
  the server-stamped time, as before, so that case is as forgeable as it
  always was. A server can still choose a *shorter* time; that is the
  owner's decision (shorter wins). No ABI or schema change.
- **C6 wiring, franking on the wire and report routes (2026-11-07):** no
  ABI, payload version or local schema change. Server migration 0047 adds the
  write-once `message_envelopes.frank_commit` column, the `report_inbox_keys`
  and `reports` tables. Every app message is now `v: 2` with a `frank`
  member, and receivers check it against the envelope's `frank_commit`. The
  rules, the receive table, the report aad and the routes are in
  [Franking v1](#franking-v1-c6) ("What is wired"); evidence in
  `testing/evidence/C6-wiring.md`.
- **C1 prerequisite 1, one conversation's MLS failure pauses only that
  conversation (2026-11-07):** no ABI, payload, wire or server change; local
  schema 20 adds one table. Design:
  [`C1-sync-isolation`](designs/C1-sync-isolation.md), "Built slice (P1)".
  Behind `PRIVATE_MESSENGER_SCOPED_SYNC` (on by default; `0` turns it off, and then nothing here activates and
  every failure stops the device as before).
  - **I33 now.** A failure at one conversation's event (`mlsControlMissing`,
    `mlsControlMalformed`, `mlsState`, `applicationUndecryptable`,
    `applicationMissing`, `unsupportedEvent`) still stops that
    conversation at that event and never skips it. It stops the device only
    when it cannot be isolated: the server cannot serve the same event again
    from `GET /api/v1/conversations/{id}/sync-events` (route off, 403, 409,
    another event under the id), the native handle no longer answers after
    the restore, more than 1,000 conversations are paused, or the failure is
    not about one conversation (storage, no crypto, expired cursor, D70
    record limit). D54 is unchanged: control messages stay fail-closed.
  - **What a pause does.** The pause row (`local_conversation_pauses`:
    `resume_after`, failed event id/type/server id, kind, generation; no
    content) is written first. The global cursor then moves past the
    conversation's later crypto events by itself: no processed marker, no
    state change. The conversation's group stays where the failed event left
    it. Every other conversation, its sends and its sealing carry on.
  - **Outgoing work is refused for a paused conversation**, in the service
    and again inside the storage transactions: application encryption, call
    signals, staging a commit (membership, self-update, revocation),
    finishing or abandoning a staged commit, and the MLS outbox send. Queued
    items stay queued. Leaving is allowed.
  - **Retry is explicit and replays.** It reads the conversation's own
    stream from `resume_after`, applies the events in order up to the global
    cursor only, with each event's effects and the new `resume_after` in one
    transaction and the global cursor and counter rules unchanged
    (`counter + 1`), then removes the pause. A failure pauses it again at
    that event. Events above the global cursor are left to the global
    stream. A different event under the failed id keeps the original
    failure. Nothing is skipped, retried in a loop or reset.
  - **Storage rule.** A transition behind the global cursor is accepted only
    for a paused conversation, above `resume_after`, at or below the cursor,
    and it does not move the cursor; a cursor-advancing transition for a
    paused group is refused. Cleared with the cursor and MLS state whenever
    those are replaced (identity change, backup restore, clear).
  - **Not done.** The design's account stream, per-scope cursors and
    `ScopedMlsTransition` are not built (see the design note). A leftover
    pause of a conversation the user was removed from stays until the group
    is dropped.
  - Tests: `mobile/test/c1_conversation_pause_store_test.dart`,
    `mobile/test/c1_native_pause_test.dart`,
    `mobile/test/app_state_catch_up_test.dart`,
    `mobile/test/chat_sync_paused_test.dart`,
    `server/internal/httpapi/scoped_sync_handlers_test.go`.

- **K1-1, backup container seal, peek and open, ABI 19 (2026-11-07):**
  additive; the Dart binding and the header now pin ABI 19 exactly (built as
  ABI 16, renumbered at integration after L1 and K2 took 14 to 18). Design:
  [`K1-automatic-backups.md`](designs/K1-automatic-backups.md), owner
  defaults D91. Nothing calls it yet: no app, server or schema path uses the
  container until K1-2 and K1-3. **Needs the independent crypto review
  before release.** Vector: `testing/vectors/k1-backup-v1.json` (Rust checks
  all of it; Dart checks the header and a seal/open round trip). Code:
  `crypto/rust/src/history.rs`, `history_backup_tests.rs`, `ffi.rs`.
  - **New symbols.** `pm_crypto_backup_seal`, `pm_crypto_backup_peek` and
    `pm_crypto_backup_open`.
  - **Container.** VHC1 kind 1, exactly as
    [`K0-long-lived-key.md`](designs/K0-long-lived-key.md) specifies: HPKE
    base mode (DHKEM X25519, HKDF-SHA256, AES-256-GCM) seals `FK ||
    nonce_prefix` to `rk_pub` with `info = "veritra-k0-seal-v1" |
    lp(account_id)` and `aad = H0`; the chunk context hashes the full header
    `H = H0 | lp(enc) | lp(sealed_fk)`, so any header byte, `enc` included,
    is bound. `enc` is 32 bytes and `sealed_fk` 56. The header carries
    account, source device, creation time, counter and `rk_id`, which Seal
    derives from `rk_pub` itself. The file key is fresh per backup and never
    leaves Rust.
  - **Open** takes the 30-byte RK entropy and derives `rk_sk` inside Rust
    (`recovery::derive_hpke_key_pair`); the private key never crosses the
    ABI and is wiped on drop. It refuses another account, another `rk_id`
    (before any HPKE work), another source device (only when the caller
    pins one; a file restore passes none and reads the device from the
    returned header), a kind-2 bundle, a non-canonical padded size or
    non-zero padding.
  - **Peek** reads the header from the first 416 bytes and returns account
    id, device id and a 41-byte meta (`created_at_ms`, `counter`, `rk_id`,
    `plaintext_version`, `padded_size`). It authenticates nothing; it exists
    so the app refuses a wrong key or device before downloading the body.
  - **Padding.** The padded size is Signal's attachment bucket of the framed
    payload (`1.05^k`, built by repeated multiplication as
    `paddedAttachmentSize`), at least 1 MiB, rounded up to the 64 KiB frame,
    at most 64 MiB. The payload must be non-empty and at most 64 MiB - 8. A
    test pins the bucket sizes against an independent Python computation, and
    the Dart test checks them against `paddedAttachmentSize`.
  - **Refactor.** The K2 bundle (kind 2) shares the header reader and the
    chunk decoder; its bytes and tests are unchanged.

- **C1 invitation binding v2, ABI 21 (ported 2026-11-09):** an
  allowlist entry only; no function, struct or length changed. The current
  header and Dart binding pin ABI 21; local schema 32 stores group invite
  anchors and server migration 0066 stores signatures. The label
  `veritra-invite-binding-v2` joins
  `SIGN_DOMAINS` in `crypto/rust/src/c7.rs`, so `pm_crypto_c7_sign` and
  `pm_crypto_c7_verify` accept it; the header and doc comments list it. A
  library without the entry refuses the domain (`PM_CRYPTO_INVALID_ARGUMENT`),
  so an app built against it fails closed. A test pins that no domain label is
  a prefix of another. The Dart binding adds lookups for the existing
  `pm_crypto_c7_sign` and `pm_crypto_group_member_signature_key` (device-level
  calls) behind `InviteBindingCryptoService`. Layout, vector and limits:
  [`C1-invite-format.md`](designs/C1-invite-format.md); vector
  `testing/vectors/invite-binding-v2.json` (Rust, Go and Dart). **Needs the
  independent crypto review before release.**
- **C7 step 2, history primitives, ABI 13 (2026-11-07):** additive; the Dart
  binding and the header now pin ABI 13 exactly. Design:
  [`C7-channel-history.md`](designs/C7-channel-history.md) revision 7 (owner
  decisions D83 to D85; D80 approved the ABI in principle). Nothing is wired
  into send, receive, the server or the schema, and no payload type is
  registered. **Every piece below needs the independent crypto review before
  release; the exporter use first.** Vector:
  `testing/vectors/c7-primitives-v1.json` (Rust checks all of it, Dart the
  stateless calls; Go follows with step 3). Code: `crypto/rust/src/c7.rs`, `mls.rs`,
  `ffi.rs`.
  - **Commit calls return what happened.** `pm_crypto_group_c7_process_commit`
    and `pm_crypto_group_c7_merge_pending_commit` (the plain calls stay)
    write `out_flags` (Remove, Add, this device removed), `out_epoch` (the
    epoch the commit produces) and, for a removal commit that keeps this
    device, a 32-byte `root`: `MLS-Exporter("veritra-c7-rekey-v1",
    lp(group_id) | u64(new_epoch), 32)` (RFC 9420 section 8.5), taken from
    `StagedCommit::export_secret` (another device's commit, after
    `inspect_commit`) or `group.pending_commit()` (this device's own) before
    the merge. The flags come from the staged commit's Add and Remove
    proposals, never from a server label, so a removal the server calls an
    add still reports a removal and a root. A commit that removes this
    device returns OK with `REMOVED_SELF` and no root; the group store is
    dropped as before (D70). The merge call refuses a group with nothing
    staged. All outputs are checked before processing and are zero on
    failure. Only the staged path reports: `pm_crypto_group_remove_member`
    and `pm_crypto_group_self_update` merge at once and report nothing, so
    the app must not use them for C7 groups. No other exporter output
    leaves the core and there is no stand-alone exporter call.
  - **Derive, commit, seal, open.** `pm_crypto_c7_derive` is HKDF-SHA256
    (salt = label, ikm = the 32-byte key, info up to 1024 bytes, 32 bytes
    out) over the labels `veritra-c7-post-v1`, `veritra-c7-rekey-chk-v1` and
    `veritra-c7-slot-v1` only. `pm_crypto_c7_chk_commit` is
    `sha256("veritra-c7-chk-v1" | key)`. `pm_crypto_c7_seal` and `_open`:
    `kc[32] | nonce[12] | AES-256-GCM(K_enc, nonce, plaintext, aad)` with
    `K_enc` and `kc` derived from the key under the internal labels
    `veritra-c7-enc-v1` and `veritra-c7-kc-v1`, a random nonce, a required
    aad of 1 to 1024 bytes and a plaintext of up to 64 KiB plus 64. Open
    checks `kc` first, in constant time: another key is the new status
    `PM_CRYPTO_C7_KEY_MISMATCH` (-10) and nothing is decrypted; the right key
    with altered bytes or aad is `PM_CRYPTO_ERROR`. A slot of a
    `history_sync` is the same seal under `slot_key` (derive with the slot
    label), so there is no separate slot call. C7 length prefixes are u16
    big-endian (C6 franking uses u32).
  - **Sign and verify.** `pm_crypto_c7_sign` signs `domain | message` with
    the device's credential key; `pm_crypto_c7_verify` is strict Ed25519 and
    stateless. The domains are `veritra-c7-post-sig-v1`,
    `veritra-c7-history-v1` and, since the C1 invitation binding v2 entry
    below, `veritra-invite-binding-v2` only, and Rust prepends the label, so
    a signature of one of them cannot be an MLS signature or a signature of
    another domain.
  - **Epoch-returning decrypt and member key.** `pm_crypto_group_c7_decrypt`
    is `pm_crypto_group_decrypt` plus `out_epoch`; its errors are the plain
    call's. `pm_crypto_group_member_signature_key` reads a member device's
    signature key from the current tree (an unknown device, or leaves of one
    identity with different keys, is an error).
  - **`inspect_commit` refuses a changed signature key.** An Update proposal
    or update path must keep the leaf's identity and its signature key;
    previously only the identity was checked. A device replacement (Remove
    plus Add of one identity) still changes the key and rekeys. A test
    builds the refused commit through OpenMLS's `self_update_with_new_signer`.
  - **History pieces in Rust (`c7.rs`, no ABI).** The generation entry (80
    bytes padded to 128), `slot_plain` (record 512 + entry 128), `P(N)` and
    the `history_sync` body length `P(N) + 124 + 700 N` with its inverse, the
    full history record (512 bytes, at most 481 used) and its compact forms
    (143 bytes; a move adds `lp(close_group_id)` and a 128-byte wrap), the
    signed-field builders and the record hash. They check structure only;
    the ordering table, freshness and authority stay with the app (step 4).
  - **Not in this step.** The ordering-row, window and implicit-genesis
    vectors, the 512-byte VAP1 slack check and the Go check of the vector
    wait for steps 3 and 4. The exporter root cannot be pinned as a
    constant (OpenMLS cannot start a group from fixed secrets); tests pin
    it as "the staged export equals the export of the merged epoch" for
    another device's commit and for this device's own, in several groups
    and epochs. The Dart binding adds only the stateless calls (derive,
    chk_commit, seal, open, verify); the device-level calls come with step 4.
  - No new crate and no Cargo.lock change (D84).
- **C7 steps 3 and 4, vectors, Go check and Dart building blocks (2026-11-07):**
  no ABI change (counters stay ABI 13, schema 20, migration 0050); nothing is
  wired into send, receive, the database or the server, and no payload type is
  registered. Every ABI 13 piece still needs the independent crypto review
  before release. Evidence: `testing/evidence/C7-steps3-4.md`.
  - **Vector** `testing/vectors/c7-ordering-v1.json`: every row of the
    ordering table (Trace 2 plus the other rows, invalid records, `unsure`
    and `keyless` moves), the implicit genesis, the generation windows
    (decision 6) and the VAP1 slack (the compact record message is a 512-byte
    VAP1 with 19 bytes spare; a move is 768 with 55). Dart checks it with the
    app logic, Go re-writes the table and re-derives every value of
    `c7-primitives-v1.json` from the inputs
    (`server/internal/c7vector`, standard library only), Rust checks that the
    vector is well formed and that the window and slack arithmetic follow the
    core's sizes.
  - **Dart device calls** (`NativeCryptoDevice`): `c7ProcessCommit` and
    `c7MergePendingCommit` (outcome and exporter root, `C7CommitOutcome`),
    `c7Decrypt` (plaintext and epoch), `c7MemberSignatureKey`, `c7Sign`.
  - **Dart logic** (`mobile/lib/crypto/c7_history.dart`, `c7_keys.dart`):
    full and compact record codecs, the ordering table as an immutable
    per-channel state, the window check, the sender-key rule (tree key, else
    the server's list and "from a former member", else drop), the key
    schedule and body helpers. `AppPayloadCodec.framedLength` exposes the
    bucket arithmetic.
  - **Reading of the table to confirm at review:** a `closed` channel leaves
    `closed` only through a live switch or move above the highest valid
    `seq` (row 5, or row 3 when it also chains from the head); every `full`
    channel keeps the highest miss epoch and only a record or slot above it
    returns `unsure` or `keyless` to `ok`; a record whose chain shape is wrong
    (create not at seq 0 with zero `prev`, or a non-create at seq 0) is
    invalid before the table; a valid record has `seq <= 2^31` and at most
    1024 above the highest valid `seq` seen (owner answer 2026-11-08), so
    recovery room always remains; row 5 and row 1 start a new period.
  - **Not built:** persistence (local schema), `history_sync` assembly and
    handling, rekey at the three merge sites, targeted-action sealing, the
    backward walk, two-pass import, prefetch and the UI marking. They need a
    local schema bump (the C7 tables in `backup_exclusion.dart`), which this
    package may not take.
- **B3 polls (2026-11-07):** additive, app layer only (no ABI, schema,
  migration or server change). `poll` and `poll_vote` payload types turned
  on (wire names `poll`, `poll_vote`); votes live in the poll row's body, so
  no `local_poll_*` table exists. `poll_close` was turned on afterwards
  (D96): the close sets `closed` in the same body, again with no counter
  bump. Details:
  section "Application payload v2", 5.5 and 8;
  `testing/evidence/B3-polls.md`.
- **B2 link previews (2026-11-07):** additive payload v2 field
  `link_preview` on `text` and `reply` (§5.8). The sender's app builds the
  preview and sends it inside the encrypted message; receivers and the
  server never fetch. No ABI, server API, migration or local schema change
  (counters stay ABI 12, schema 18, migration 0046): the received preview
  lives in the existing `format_json`. Adds one Dart dependency, `html`
  0.15.7 (with `csslib` 1.0.2); the owner's approval is not yet recorded as
  a decision in STATE.md, so the merge waits for it. A preview never leaves
  the device in a K2 history snapshot or a backup: both writers remove the
  whole `link_preview` key from `format_json` (about 22 KiB of thumbnail a
  row would push a long history over their 64 MiB caps, and a build older
  than B2 rejects a snapshot with the key). The K2 reader still accepts it.
  Keeping previews across a transfer needs a snapshot/backup format bump,
  which is a separate decision.

- **C6 foundation, report seal and franking commitment, ABI 12
  (2026-11-01):** additive; the Dart binding and the header now pin ABI 12
  exactly. Design: [`C6-reports-franking.md`](designs/C6-reports-franking.md)
  (D80: reports are sealed to the recipient's key; new HPKE ABI functions
  approved with independent review). No wire, payload, server or schema
  change: nothing sends a report or a `frank` member yet.
  - **Report key.** `pm_crypto_report_key_generate` returns a 32-byte seed
    from the OS RNG; the recipient app keeps it. `pm_crypto_report_key_public`
    derives the X25519 public key: PRK = HKDF-Extract(SHA-256, salt
    `veritra-c6-report-key-v1`, ikm seed), `HKDF-Expand(PRK, "veritra-c6
    report-hpke", 32)` into RFC 9180 DeriveKeyPair (DHKEM X25519). No X25519
    private key crosses the ABI: open takes the seed and derives the pair in
    Rust. The seed crosses it (owned, zero-on-free buffers), as the K0
    entropy and the state key do, because the app must store it.
  - **Seal and open.** `pm_crypto_report_seal(recipient_public, aad,
    plaintext)` and `pm_crypto_report_open(seed, aad, sealed)`: RFC 9180
    base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM (the
    suite K0 and K2 use), through `OpenMlsCrypto::hpke_seal/hpke_open` of
    `openmls_rust_crypto` (hpke-rs 0.7, already in the graph and reviewed;
    no new crate, no `Cargo.lock` change). `info` is fixed in Rust as
    `veritra-c6-report-v1`, so a report key opens nothing sealed for another
    purpose and no K0/K2 key opens a report. The output is `"VRP1" || enc
    (32) || ciphertext`. `aad` is required (1 to 1024 bytes): the report
    transport (C6 build step 3) fixes its layout and must bind at least the
    recipient inbox and the report's routing fields. Plaintext 1 byte to 256
    KiB. A bad or low-order public key (all-zero DH output, RFC 9180 §7.1.4)
    is `PM_CRYPTO_INVALID_ARGUMENT`; altered bytes, another aad or another
    key on open is `PM_CRYPTO_ERROR`. Base mode does not authenticate the
    sender: who filed a report comes from the server's authenticated route,
    and what was said from franking.
  - **Franking commitment.** `pm_crypto_frank_commit(key, conversation_id,
    sender_device_id, action_id, payload)` returns `HMAC-SHA256(kf,
    "veritra-frank-v1" || lp(conversation_id) || lp(sender_device_id) ||
    lp(action_id) || lp(payload))`, lp a u32 big-endian length, byte for
    byte `server/internal/franking`. `kf` 32 bytes, ids 1 to 128 bytes,
    payload 1 byte to 64 KiB. The payload is the canonical bytes `P` of
    [Franking v1](#franking-v1-c6) below. The app compares commitments in
    constant time (`frankCommitEquals`).
  - **Known-answer vector.** `testing/vectors/c6-franking-v1.json` (the
    commitment, `P` and its wire JSON, a seed, its public key and one sealed
    report), checked by `crypto/rust/src/report_tests.rs`,
    `server/internal/franking/franking_test.go` and
    `mobile/test/c6_report_crypto_test.dart`. The Go test derives the public
    key with Go's own HKDF and `crypto/hpke` DeriveKeyPair and opens the
    Rust-sealed report with `crypto/hpke`, an independent RFC 9180
    implementation (test only; the server never opens reports).
    The vector also holds extra commitment cases (a `channel_id` and
    `hidden` payload, escaped and multi-byte UTF-8 text), one report sealed
    by Go's `crypto/hpke` that Rust and Dart open, and the malformed `frank`
    spellings, which Rust and Go check with a strict test-side reader and
    Dart with `splitFrank`. Review fixes (2026-11-06, no ABI change):
    `franking.Commit` now has the Rust size bounds; `report_seal` refuses
    every low-order X25519 point (including non-canonical spellings) as
    invalid input and maps any other seal failure to `PM_CRYPTO_ERROR`;
    `frankWireJson` refuses an empty object.
  - **Dart.** `ReportCryptoService` (`crypto_service.dart`), implemented by
    `NativeCryptoService`; `UnavailableCryptoService` refuses every method
    with `StateError`. `mobile/lib/crypto/franking.dart` holds the `P` and
    wire rules; `AppPayloadCodec.encodeFranked` writes a franked payload.
    Both are used by the send and receive path since the 2026-11-07
    wiring (see "Franking v1").

- **Server key-package parsing (2026-11-01, TASK-172):** no ABI or wire
  change. The server now refuses a device key package that does not parse as
  one bare RFC 9420 KeyPackage in the client's suite (rules in the
  key-package paragraph above), with 400 `invalid_device_key_package`, or
  `invalid_key_packages` on publish. Packages already stored are not
  rechecked. Signatures and the credential binding stay unverified (open
  question Q-1). Fixture: one package from `create_key_package` at commit
  1a21ee2, in `server/internal/mlswire/mlswiretest`.
- **K0 R1, recovery key and recovery proof, ABI 11 (2026-11-01):**
  additive; the Dart binding and the header now pin ABI 11 exactly. Design:
  [`K0-recovery-enrollment.md`](designs/K0-recovery-enrollment.md) (D78).
  - **New symbols.** `pm_crypto_recovery_key_generate` (30 bytes of OS
    entropy), `_encode` and `_decode` (52 Crockford base32 characters of
    entropy ‖ `SHA-256("veritra-k0-rk-check-v1" ‖ entropy)[0..2]`; decode is
    case-insensitive, reads O as 0 and I/L as 1, ignores `-` and spaces, and
    refuses any other symbol, a wrong check or non-zero padding bits),
    `pm_crypto_recovery_key_derive` (`rk_pub`, `rk_id`, `rk_auth_pub`) and
    `pm_crypto_recovery_proof_sign`.
  - **Derivation.** PRK = HKDF-Extract(SHA-256, salt `veritra-k0-v1`, ikm
    entropy). `HKDF-Expand(PRK, "veritra-k0 recovery-hpke", 32)` feeds RFC
    9180 DeriveKeyPair (DHKEM X25519) for `rk_pub`; `rk_id =
    SHA-256("veritra-k0-rk-id-v1" ‖ rk_pub)[0..16]`; `HKDF-Expand(PRK,
    "veritra-k0 recovery-auth", 32)` is the Ed25519 seed of `rk_auth_pub`.
    `L` stays reserved and unused. No private key or seed crosses the ABI;
    the entropy does (owned, zero-on-free buffers), because the app shows it.
  - **Proof.** Ed25519 by the RK auth key over exactly what
    `recoveryProofMessage` (`account_recovery_handlers.go`) rebuilds:
    `"veritra-k0-recovery-proof-v1" | lp(challenge) | signing_key (32) |
    SHA-256(key_package) | lp(origin)`, lp a u16 big-endian length. The label
    is fixed in Rust, so the key signs nothing else. Bounds: challenge 1 to
    4096 bytes, key package 1 byte to 48 KiB, origin 1 to 2048 bytes of UTF-8
    with no control or space characters; anything else is
    `PM_CRYPTO_INVALID_ARGUMENT`.
  - **Known-answer vector.** `testing/vectors/k0-recovery-v1.json`, checked
    by `crypto/rust/src/recovery_tests.rs`, by
    `server/internal/httpapi/account_recovery_vector_test.go` (which derives
    the display, `rk_pub`, `rk_id` and `rk_auth_pub` again with Go's own
    HKDF, X25519 and Ed25519, rebuilds the message with the production
    `recoveryProofMessage`, verifies the signature and reproduces it byte for
    byte) and by `mobile/test/k0_recovery_native_test.dart`.
  - **Dependency.** `ed25519-dalek` 2.2.0 (BSD-3-Clause) becomes a direct
    dependency (D78); it was already built through `openmls_basic_credential`
    and `openmls_rust_crypto`, so only the direct edge is added to
    `Cargo.lock`.
  - No server, payload or schema change. The app does not call these yet:
    R3 (setup) and R4 (recovery) wire them.

- **L1-2, approved-device list, server (D94, 2026-11-07):** server migration
  0051 (no ABI, payload or local schema change). The server stores each
  account's signed VDL1 chain and serves it to the account and its
  conversation peers; see "Approved-device lists" in `docs/operations.md` and
  `docs/designs/L1-approved-device-list.md`. The server verifies, as defence
  in depth, every upload with the design's rules (package
  `server/internal/devicelist`): strict parse (ids 1 to 128 bytes, listed keys
  and the recovery key canonical non-small-order points, as the crypto core
  checks), version = head + 1, `prev_hash`, signer by change kind (a change 5
  must change the recovery key), Ed25519 signature (Go `crypto/ed25519`; signed
  message `"veritra-l1-device-list-sig-v1" | SHA-256(body) | signer kind |
  lp(signer)`, `list_hash = SHA-256("veritra-l1-device-list-hash-v1" | body)`),
  no return of a removed id or key, one key per device, and that each listed
  device exists live in the account with the same `signing_key`. The shared
  vector `testing/vectors/l1-device-list-v1.json` belongs to L1-1;
  `server/internal/devicelist/vector_test.go` runs the production parse and
  check over it (both chains, every refusal in its class, the Ed25519 edge
  cases) and skips while the file is absent. It passed against L1-1 at
  `4c2b5ff`. A recovery completion onto a list with no recovery key is refused
  (410, request cancelled), as the claim is.
  The new `device_list` field on setup, register, link approval (v2, v3),
  revoke and `PUT /account/recovery-key` is optional, required only once the
  account has a list (link approval, recovery key); a revoke without it stays
  allowed. Honest-server gates (pending changes, claims, commit bundles) apply
  to accounts with a list. A recovery claim on a list with no recovery key is
  refused as no key at all and not counted toward D79. The key-package leaf
  signature-key gate (Q-1) is not built here. Independent review of L1-2 is
  still owed.

- **Coordinator notice (D96, 2026-11-07):** no ABI or schema change (the
  event type is free text, so migration 0050 is not needed). When a device
  link is approved, on the v3 route and on the legacy v2 route the shipped app
  still uses (`POST /api/v1/device-links/{id}/approve`), the server writes one
  `device.member_linked` account event for each other account whose device is
  the lowest-id live device of an MLS group the linking account belongs to (at
  most 64), in the same transaction as the device row, and publishes it live
  after `device.updated`. The event-less `ApproveDeviceLink` store call
  writes none. Payload: `account_id` and `device_id` of the link, nothing
  else, no conversation id. The client starts a membership pass on it; only
  the coordinator acts, the others keep the 3-minute fallback. Not covered:
  coordinators beyond the 64 cap. K0-R recovery: see the next entry.

- **Coordinator notice for K0-R (D96, 2026-11-11):** no ABI, schema,
  migration or client change. Found by K1-7: a recovered device was added by
  peers only through the L1 complete-adds audit (15-minute interval, then the
  3-minute fallback), and nothing woke them. Now the change-4 version a
  recovered device posts (`POST /api/v1/account/device-list`) writes the same
  `device.member_linked` notices as a link approval, in the version's own
  transaction, and the route publishes them live after
  `device_list.updated`. Same recipients (one per other account whose device
  coordinates an MLS group the recovered account is in, at most 64), same
  payload (`account_id`, `device_id`, no conversation), same type, so a peer
  cannot tell a recovery from a link by the notice; it already reads change 4
  in the account's list. It is written at change 4, not at recovery
  completion, because only then is the device on the list head, so the
  pending-change list names it (`deviceOnHeadSQL`) and a coordinator can add
  it. Change 4 lands at most once per device (the chain refuses a returning
  device, and the route accepts it only from the completed recovery's device
  while it is the account's one active device), so one recovery fans out at
  most once; a refused or replayed version writes nothing. Changes 3 and 6
  write none. No push wake: link approval sends none either (push wakes are
  for new messages and the K0-R own-account wake), so an app that is closed
  finds the durable notice at its next catch-up and runs the pass then.
  Not covered: pre-L1 accounts with no device list, which post no change 4.
  Tests: `server/internal/httpapi/account_recovery_member_notice_test.go`;
  `mobile/test/demo_e2e_test.dart` K1-7 now runs with the client's audit
  interval and fallback unchanged and no app resume.

- **K0 R2 review, legacy-group revocation coordinator (2026-11-01):** no
  ABI, payload or schema change. In a legacy group (no recorded roster),
  the `coordinator_device_id` that `GET /api/v1/mls/revocations` reports now
  skips devices with no evidence of a leaf. Evidence means the device sent
  an MLS message in the conversation, received a Welcome there, or is no
  newer than the oldest retained MLS message. Revocations queued in a legacy
  group store such a coordinator and require confirmations only from such
  devices. A device recovered through K0 has no leaf, so it is skipped while
  the group keeps an MLS message older than the device. Known limit
  (accepted; legacy groups come only from pre-I51 data and there are no real
  users, D55): once sync retention prunes every older message, the third
  rule admits it again and a revocation can wait on it. A durable per-group
  low-water mark would close this and needs a schema change.

- **D70 S3, per-record sealed state, ABI 10 (2026-10-31):** sealed state
  format 4 (see "Sealed state, format 4" above). ABI 10 removes
  `pm_crypto_device_restore` and `pm_crypto_device_seal_state` and adds
  `pm_crypto_device_seal_changes`, `pm_crypto_restore_begin`, `_add`,
  `_finish` and `_abort`, `pm_crypto_device_migrate_v3`,
  `pm_crypto_group_delete`, `pm_crypto_device_prune_key_packages`, and the
  codes `PM_CRYPTO_RECORD_LIMIT` (-8) and
  `PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE` (-9, D74). The Dart bindings
  pin ABI 10 exactly. No server or payload change; schema 16 (S2) holds the
  records.
  - **Behaviour changes.** A device that applies its own removal no longer
    keeps an inactive group: `groupEpoch` is null and later messages are
    D54 placeholders. A Welcome for a missing or expired key package is a
    notice row instead of a sync stop. Key packages are capped at 1,000.
  - **Migration.** One way, at activation, in one compare-and-swap
    transaction that does not move the sync cursor. A build before ABI 10
    cannot read the migrated state; it reports `stateFormatUnsupported`.
  - **App wiring (S4, 2026-11-01).** A caught-up foreground sync pass
    prunes expired key packages (at most every 6 hours); replenishment
    prunes first and keeps a partial batch, so the 1,000 cap never blocks
    it for good. Leaving a conversation notes it durably; the next
    foreground pass (or a Welcome for that conversation, foreground only)
    calls `deleteConversationState`, which also settles its queued MLS
    messages. `PM_CRYPTO_RECORD_LIMIT` rolls back and shows a localized
    message; in sync it is a `recordLimit` stop that names the
    conversation and offers to leave it.
  - Tests: `crypto/rust/src/mls/records_tests.rs`,
    `crypto/rust/src/ffi/records_tests.rs`,
    `crypto/rust/tests/rejoin_after_removal.rs`,
    `mobile/test/d70_crypto_records_changes_test.dart`,
    `mobile/test/d70_native_records_service_test.dart`.

- **D54, undecryptable peer messages (2026-10-31, owner decision):** no
  ABI, payload, schema or server change. A peer's application message or
  call signal this device can never decrypt no longer stops the global
  sync cursor (I33); MLS control messages still do.
  - **Which errors qualify.** Only `operationFailed`, `nativePanic` and
    `invalidOutput` from `decrypt`. `invalidArgument`, `unknown` and any
    other kind roll back and stop sync as before. `senderMismatch` and
    `senderRemoved` keep D25 (`unverifiable` row).
  - **Restore, retry, restore, reseal.** After a qualifying error the
    committed group is restored from the sealed state and `decrypt` runs
    once more on the fresh handle: the failed attempt may have changed the
    group in memory, and a Rust panic poisons the old handle's mutex, so
    one failure never costs a message. Only a second qualifying failure
    passes the event: the group is restored again, then the same state is
    resealed with the event's marker and the cursor.
  - **Row.** An application message gets an `invalid` row keyed
    `undecryptable:<syncEventId>:<envelopeId>`, with no body, shown as
    "Couldn't unlock this message". A call signal is dropped with no row.
  - **`groupEpoch`** after a native error probes the handle with a call
    that takes the same device lock. A handle that answers and holds the
    stored state means the group is simply missing (no restore); otherwise
    it reloads the committed state and asks again, so a poisoned handle
    never reads as "no group".
  - **Fork check.** An own-device commit with no queued bundle passes only
    when the group is already past the epoch in the commit's clear MLS
    header (the outbox worker merged and settled it). Otherwise, as for a
    clone-restored twin or an accepted commit this device dropped, sync
    stops there instead of turning the fork into placeholders.
  - **Abandon** clears a pending commit only when it is pending on the
    bundle's own epoch, so a refusal that arrives after another device's
    commit won cannot drop a newer staged commit.
  - **Residuals.** An empty or oversized ciphertext (`invalidArgument`)
    still stops sync. A bundle (a self-update too) whose acceptance was
    lost and whose retry got 403 `forbidden` is abandoned; its own commit
    would then stop sync at the fork check. The server answers 403 there
    only when the account left the conversation or the device was
    revoked, and sync no longer delivers a left conversation's events, so
    only a revoked device can meet it. Second case: the account left, the
    bundle was abandoned, and the account is re-invited. Until the MLS
    re-add lands, the old roster window shows the old own commit again
    (`mls_group_store.go`, join filter) and the fork check stops sync.
    This is transient: the re-add moves `joined_after_event_id` past it.
  - Tests: `native_crypto_service_policy_test.dart`,
    `native_crypto_service_d54_review_test.dart` (fault-injected native
    errors) and `chat_undecryptable_placeholder_test.dart`.

- **Sync cursor expiry from prune watermarks (2026-10-31):** server
  migration 0044; no ABI, payload, client or API change. I33 still holds:
  an expired cursor gets 409 `device_recovery_required` and the app never
  jumps ahead.
  - **Bug.** The server said a cursor had expired when the cursor's own
    event was pruned and the account's oldest remaining visible event was
    more than one id past it. Sync event ids are global, so other accounts'
    events nearly always filled that gap. A device that missed nothing got
    409, and Relink, the only recovery the app offers, needs a second
    device. After the previous entry this hit sign-in after more than event
    retention (30 days by default). It also hit a quiet account that stayed
    signed in, and any cursor below the account's first event, with
    nothing pruned at all.
  - **Rule.** A cursor has expired when retention pruned an event after it
    that the device could have been sent. Triggers on `sync_events` keep,
    in the same transaction as each delete, the highest pruned id in three
    places:
    - each account, per target device (`''` for events every device of the
      account receives);
    - each conversation, split into the events sync filters by the MLS join
      cursor (`mls.message.created`, `message.envelope.*`, `call.*`) and the
      rest;
    - the whole table (`sync_prune_state.pruned_through`).
    A cursor at or past the table's mark lost nothing: one primary-key read,
    the usual case. Otherwise it has expired when any of these is past it:
    - the account's mark for every device, or for this device;
    - the plain mark of a conversation the account is a member of now;
    - the MLS-filtered mark M of such a conversation, when there is no MLS
      group, or when the device's roster row has M > `joined_after_event_id`
      and either no `removed_after_event_id` or one past both the cursor and
      the join.
  - **Not counted.**
    - Another device's Welcome.
    - A conversation the account left. Its own `membership.left` event is an
      account event, which does count.
    - MLS events from before the device joined.
    - Message events whose message had expired, was deleted (apart from the
      delete marker) or was gone when pruned. Sync hides those from every
      cursor, so disappearing messages do not expire a cursor.
  - **Still conservative (expired although nothing visible was lost).**
    - A pruned event from a sender the account blocked. Marks keep no
      sender, because a mark per sender would keep who wrote where, and in
      what order, beyond retention.
    - A late message from an epoch before the device's `joined_epoch`.
    - A removed device whose roster window reaches past the cursor while
      the newest pruned MLS event lies after the removal.
    - Plain conversation events (membership changes, reactions, read
      receipts, `conversation.updated`) from before the account was added.
      Memberships have no join cursor, so sync serves these to every
      current member, and the old check counted them too. A user added to
      an active group while away for longer than retention still gets 409.
      Fixing it needs a per-membership join cursor (a schema change).
    Each needs the device's cursor to fall more than one retention period
    behind, and the only events it lost must be of one of these kinds. A
    device online and polling can still fall that far behind: hidden events
    do not move its cursor (STATE.md, "Hidden tail on every poll"). So a
    blocked sender who keeps writing into a DM can get the blocker 409 once
    the blocker has had no visible event anywhere for a retention period.
    The real fix is a next cursor past hidden events, an API change.
  - **Upgrade.** Migration 0044 seeds `legacy_through` with the ids pruned
    before it: the oldest remaining event id less one, or the last id ever
    issued when the table is empty. A cursor below that also gets the old
    test, which is safe but keeps its false refusals. Below that bound the
    cursor's own event is always gone, so the old test refuses as soon as
    the account has any event left: every device whose last received event
    is older than the oldest event kept at the upgrade gets 409 at its next
    event, even a quiet one that stayed online. Nothing records what those
    earlier prunes held, so treating them as lost nothing would fail open.
    Only pre-release demo databases predate 0044. The marks hold one event
    id per conversation and per account and device. They are never removed,
    so a dormant conversation's mark tells roughly when it was last active,
    even past retention.
  - **Ordering.** The check now runs after the page is read. Run before,
    a prune landing between the check and the page could drop events
    without a 409.
  - **Tests.** `server/internal/storage/sync_prune_marks_test.go`:
    - the review's reproduction;
    - real gaps (account, own-device, conversation and MLS events);
    - the cases that do not count, and the blocked-sender expiry;
    - the upgrade of an existing database;
    - the query plan.
    The read-model equivalence tests bound every cursor between "lost an
    event it could see" (must expire) and "lost an event in its streams"
    (may expire). `mobile/test/sync_recovery_test.dart` covers sign-in
    receiving `device_recovery_required`.

- **Sign-in keeps the sync cursor (2026-10-31):** no ABI, payload, schema
  or server change; I33 and D28 unchanged.
  - **Bug.** Password sign-in reset the sync cursor to 0. The cursor and
    the MLS state commit together and a sign-in keeps the state, so
    sync replayed events that state had already consumed:
    - After an I45 restore, the restore drops the applied-event markers.
      The first old commit failed and I33 stopped sync. Seen when the
      original device signed out, which revoked the session the backup
      carries.
    - After a session expiry or a sign-out, the markers skip the old
      events but do not move the cursor. With 200 or more retained events,
      sync fetched the same first page forever and never reached new
      events. Every pass also re-handled an old Welcome and published a
      new key package.
  - **Fix.** `AppState.login` keeps the cursor when the account, device
    and server are unchanged and protected MLS state was present before
    the sign-in. Otherwise it resets the cursor to 0, as before. The stores
    own the same rule: clearing cached state keeps the cursor, and a new
    identity or a full wipe sets it to 0. Before this, the database kept
    the old value on both, and only the callers' explicit reset hid that.
  - **Effect.** A device signed out for longer than server event retention
    now gets `device_recovery_required` (relink or backup) at sign-in, but
    only when retention pruned an event it could have been sent (entry
    above, migration 0044). Before, it skipped that check by asking from
    event 0.
  - **Tests.** `mobile/test/sync_recovery_test.dart` ("signing in again
    as the same identity") covers both stores. Since D71 the demo e2e
    covers a restore that finishes by linking from another device.

- **Periodic self-update (2026-10-31, research round 2):** no payload or
  local schema change, no new symbol and no ABI number change; server
  migration 0043.
  - **Why.** A device's leaf key changed only when that device committed
    with an update path, which in practice meant removing someone. Most
    devices kept the key from the key package they joined with, so a
    leaked device state stayed readable for the life of the group:
    post-compromise security rarely happened. A path commit soon after a
    join also fills the device's path in the tree, which makes later
    removals cheaper (research notes on post-quantum groups, cold trees).
    A self-update renews the leaf's encryption (HPKE) key and the path
    secrets, not the signature key or the credential: a thief holding
    the signature key can still sign as the device until it is relinked
    or removed, and L1 is what binds leaves to the signed device list.
  - **Native.** `pm_crypto_group_stage_commit` with an empty change list
    (version 1, no adds, no removes) stages a commit with an update path
    and no proposals (`MlsDevice::stage_self_update`): the proposal store
    is not consumed and every proposal is filtered out, and a result
    without a path is cleared and refused. It is staged, not merged, like
    every D28 commit. The credential and signature key are kept, so the
    safety number does not change. Receivers need no change:
    `inspect_commit` already accepts an update path that keeps the leaf's
    identity. Earlier ABI 9 builds refuse an empty list, so a mismatched
    library fails closed (the app backs off and sends nothing). The Dart
    `selfUpdate` wrapper of `pm_crypto_group_self_update`, which merges
    before any server answer and can fork the group, is removed; the
    symbol stays in the library, documented as not for app use.
  - **Server.** A commit bundle with a commit and no Added or Removed
    devices is an update-only commit. It needs an active group device of
    a member account, as every commit does, and is checked in this order:
    idempotency key (a retried accepted commit returns the stored one,
    even inside the budget), current epoch (409 `mls_epoch_conflict`),
    then 409 `mls_change_pending` while the group has a pending
    revocation or a device whose account left (removals take the epoch
    first), then 429 `mls_self_update_limit` with `Retry-After` when the
    same device made one in the conversation within
    `PRIVATE_MESSENGER_LIMIT_MLS_SELF_UPDATE_MINUTES` (default 60), unless
    the device sent a C4 leave notice there within the last hour and after
    its last self-update (the void of a cancelled leave, once per notice;
    "Cancelled leave"). The time is kept on the device's roster row. The route stays under the
    D39 request budgets and the delivery write budget. A Welcome needs an
    Added device and a revocation a Removed one, so neither can ride on
    an update-only bundle; every other check is unchanged.
  - **App.** `MlsSelfUpdatePolicy` (`mobile/lib/core/`) decides per
    conversation: once after a Welcome (30 s plus a jitter of about a
    minute per member, at most 3 h, since every device a commit adds
    joins at once); after 100 application messages sent since this
    device's last path commit (at least an hour after it); after 7 days
    plus up to 12 h when the chat had activity since. Jitter is derived
    from the device and conversation IDs. A chat first seen after an
    upgrade gets a last update spread over the past 7 days, so devices
    that upgrade together do not all update at once. AppState stages at
    most one per foreground sync pass, a minute apart, after revocations
    and reconcile, never in a background wake, and skips a group with a
    pending revocation, a listed removal, queued MLS work, a staged
    commit or a paused MLS outbox. A commit tells every member that this
    device is online, so, like a read receipt, none goes to a message
    request (or a declined one, D48) or to a DM whose peer is blocked
    (blocks loaded first); their counters wait for acceptance. Only
    refusals the server gives after its duplicate check drop the staged
    commit and back off: 409 `mls_epoch_conflict` or `mls_change_pending`
    (10 min), 429 `mls_self_update_limit` (Retry-After, at least 1 h),
    and 400, 403 or 422, such as an older server's `invalid_input`
    (24 h). These do not pause the conversation. Any other answer,
    including the write budget's 429 `write_rate_limited`, which comes
    before the duplicate check, may hide a bundle the server already
    accepted with its answer lost. Dropping it would leave this device
    an epoch behind its own commit, so the same bundle is retried
    unchanged through the MLS outbox (I34). An accepted self-update, or
    any own commit that removes a device, resets the counters, whether
    the outbox completes it or sync merges it after a lost answer. State
    is a JSON setting in the encrypted local store, bound to the account
    and device.
  - **Trust model.** The server cannot read a commit. "Update only" is
    what the sender declares, exactly as Added and Removed are for every
    other bundle, and nothing cross-checks the declaration: not the
    server, and not receivers, whose `inspect_commit` checks only the
    commit's shape (proposal types, Basic credentials, unique
    identities, identity kept on update). A malicious member's client
    could already hide an Add or Remove inside a bundle that declares
    another change. An update-only bundle widens that slightly: a hidden
    Remove no longer needs a real pending change to ride on. The
    per-device budget bounds how often. A hidden Add still needs a
    member account and the server roster to receive anything. The fix is
    L1 ("What L1 must provide"): receivers check every added and updated
    leaf against the signed device list.
  - **Open.** Commits that only add devices still carry no path, so the
    committer's key is not refreshed by them. A device that loses its
    local policy state updates early or late, never more often than the
    budget allows. A Welcome handled in a background wake notes the join
    only in memory, saved by the next foreground pass. If the process
    ends first, the note is lost: the chat is later first seen, and its
    first update is spread over 7 days instead of coming shortly after
    the join.

- **Attachment size padding, manifest v2 (2026-10-31, research round 2):**
  no ABI, chunk-crypto, AAD or upload change. Before this the server
  stored each attachment's exact ciphertext size, `plaintext + 20` bytes
  per 1 MiB chunk, so it could recognise a known file by its length.
  - **Sender.** `attachment_crypto.dart` encrypts the file followed by
    zero bytes up to `padded_size`, then seals it with the same chunking.
    The bucket is Signal's (`PaddingInputStream.getPaddedSize`):
    `max(541, floor(1.05^ceil(log_1.05(size))))`, the smallest
    `floor(1.05^k)` that holds the file. That costs at most 5% above
    541 bytes; 236 buckets in all, 80 of them between 1 MiB and 48 MiB.
    The power is built by repeated IEEE 754 multiplication, so every
    platform picks the same buckets. The bucket stops at the server's attachment cap
    (`max_attachment_bytes` from `setup/status`, at most 48 MiB, which is
    the app's own cap), so a file just under it is never refused for its
    padding. It never goes below the file's own size. The server's limit
    (`MaxAttachmentCiphertext`) is unchanged and still holds, because
    padded ≤ cap.
  - **Manifest.** `version: 2` adds `padded_size`. `plaintext_size` is the
    true length, and both travel only inside the MLS message.
    `chunk_count = ceil(padded_size / 1 MiB)`, and the ciphertext is
    `padded_size + chunk_count * 20` bytes. The upload metadata the server
    sees stays `{version: 1, algorithm, chunk_size}`, because the framing
    it sees is unchanged and a second version would label padded blobs.
  - **Receiver.** It accepts version 1 (no `padded_size` allowed) and
    version 2 (`plaintext_size ≤ padded_size ≤ 48 MiB`). It does not
    recompute the bucket, because the sender's clamp depends on its
    server's cap. Every chunk is authenticated, including padding-only
    ones. Bytes past `plaintext_size` must be zero, or decryption fails
    closed with nothing published, and only `plaintext_size` bytes are
    written. AEAD integrity and the exact-length framing check now cover
    the padded stream. The server's whole-blob SHA-256 and chunk digests
    (`server/internal/uploads/local.go`) are computed over the uploaded
    bytes, the padded ciphertext, so they still cover exactly what a
    client downloads. The manifest (MLS-authenticated, from the sender)
    alone decides the true length, as it already decided the key.
  - **Old attachments.** Version 1 manifests decrypt as before, which a
    hand-built version 1 test shows.
  - **Older apps.** An app from before this change still lists a padded
    attachment (name and size come from the manifest) but refuses to open
    it with `unsupported attachment manifest`. Nothing wrong is ever shown
    as the file. A K2 history snapshot from a new device that holds
    padded attachments is refused whole by an older receiving device
    (strict manifest check in `history_snapshot.dart`). K2 transfer is
    not wired yet, so no shipped path hits this.
  - **Cost.** Quotas and the write budget count padded bytes
    (`docs/operations.md`, Admission limits).
- **Server revocation and delete fixes (2026-10-31, storage review):** no
  ABI, wire or schema change.
  - The coordinator of a pending device revocation is now computed when
    read or committed: the one recorded when the revocation was queued while
    it is still an eligible group device (not revoked, its account a member,
    an active roster device in a rostered group), otherwise the lowest
    eligible device id. Before, a revoked or departed coordinator left the
    revocation pending for good. `GET /api/v1/mls/revocations` reports that
    device in `coordinator_device_id` and lists a pending revocation for it
    even when it joined the group later and has nothing to confirm. Only it
    may submit the revocation commit; the group's epoch check, not the
    coordinator rule, is what stops two commits from both landing.
  - Deleting an account queues the same per-group revocations as revoking
    each of its devices, so the remaining members commit the removal of its
    leaves. They are still not on the reconcile remove list, because a plain
    bundle may not remove a device with a pending revocation (Q-004).
  - A message deleted through the server's delete route has its created and
    edited sync events redacted and hidden; only `message.envelope.deleted`
    replays. A client never sees a created event without its envelope.
  - A device that must confirm a revocation and is then revoked, or whose
    account is deleted, no longer holds it: its unconfirmed rows count as
    confirmed, and a revocation whose commit is in completes with its one
    `mls.revocation.completed` event (found by sync, not pushed live).
  - Open: a device whose account only leaves the conversation still never
    confirms (confirming needs membership), so that revocation stays
    `commit_submitted`. Nothing waits on that state today.
- **Revocations only where a leaf exists (2026-10-31, roster review):** no
  ABI, wire or schema change.
  - A revoked device gets a revocation in a rostered group it is an active
    device of, and, without a roster, only in a legacy group: one with MLS
    messages, the test `CreateMLSCommitBundle` uses. Before, every
    conversation without a group row got one, including groups never
    created (setup failed, or the first bundle still in the creator's
    outbox); the named coordinator could never commit it.
  - A pending revocation whose device has no leaf (rostered group, device
    not an active roster device; or no group and no MLS messages) names no
    coordinator, so no commit for it is accepted.
    `GET /api/v1/mls/revocations` reports `coordinator_device_id` as `""`
    for a pending revocation no device can commit now, not the stale
    recorded one.
  - Creating a group, and every later commit bundle, deletes the group's
    pending revocations whose device is not an active roster device (a
    revoked device can never join, so they could never complete).
  - The client handles each listed revocation on its own: one that fails
    (no local group, no leaf) is logged without identifiers and retried on
    the next pass, and reconcile and the wake ACK still run.
  - A server-route delete redacts the message's events from its created
    event on (`idx_sync_events_conversation`), not the conversation's whole
    retained history.

- **W8 pin rule (2026-10-31, owner decision):** any member of a DM or a
  group may pin; community conversations keep moderator roles until C4. The
  limit rises from 3 to **50** active pins per chat (per channel in a shared
  community conversation); the 51st evicts the oldest by `pinned_at`. A
  group admin-only switch waits for C4, because groups have no encrypted
  settings record yet. Mixed versions disagree until updated: an older app
  drops a group member's pin and keeps only 3. Payload bytes are unchanged.
- **Crypto-core fixes, ABI 9 (2026-10-31, audit plan 2026-10-25):** one
  ABI bump for the whole set; the Dart binding requires 9 exactly.
  - TASK-007: `pm_crypto_device_sign_enrollment_challenge` is removed. It
    signed caller-chosen bytes with the MLS identity key, so a server could
    obtain a valid signature over any RFC 9420 `SignContent` (a leaf node,
    key package or framed content). No server or app path verified a
    raw-challenge signature (only the prefixed proof of
    `pm_crypto_device_create_enrollment_credential`, unchanged), so nothing
    on the server changes.
  - TASK-001: every output buffer is an exact-length allocation; a Vec with
    spare capacity is copied and the original wiped instead of shrunk by a
    realloc that could free it unwiped. Outputs refused for a NULL target are
    wiped. encrypt/decrypt check the output pointer before using a ratchet
    step. `pm_crypto_buffer_free` already wiped non-elidably.
  - TASK-002: decrypt accepts MLS ciphertext up to 1 MiB + 4096 bytes and
    encrypt never returns more, so every 1 MiB plaintext round-trips through
    the FFI. That is the native ceiling, not what the app can send: see
    "Message size".
  - TASK-003: an account/device identity occupies one leaf. Adds that would
    repeat an identity in the resulting roster are refused, and removing a
    device removes every leaf that carries its credential.
  - TASK-004: a remote commit is inspected before it is merged: member
    sender only; Add, Remove and Update proposals only; Basic credentials
    holding well-formed, unique device identities; updates keep the leaf's
    identity. A refused commit leaves the stored epoch unchanged.
  - TASK-005: a Welcome is checked before its group is stored: expected
    group id, well-formed unique identities, this device's own identity and
    signing key on its leaf, a sender that is another leaf. A refused
    Welcome stores nothing, but staging has already consumed the key package.
  - TASK-008 (decides Q-003): a message decrypted from one of the two
    retained past epochs (I51) is refused when its sender is no longer in
    the group, so a removed device cannot keep writing by never applying
    its removal. The cost: a committer that merges a removal on acceptance
    drops the removed device's genuine late message too; the receiver
    cannot tell the two apart. The new code `PM_CRYPTO_SENDER_REMOVED` (-7)
    is handled exactly like D25's sender mismatch: the ratchet advanced, so
    the state and cursor commit with an `unverifiable` row. Mapping it to
    `PM_CRYPTO_ERROR` instead would roll back and stop global sync (I33)
    on that honest race. The check compares identities only; past-epoch
    signature keys are not exposed by OpenMLS.
  - TASK-009: `pm_crypto_device_restore` returns
    `PM_CRYPTO_STATE_FORMAT_UNSUPPORTED` (-6) for sealed state with the
    right magic and a format version this build does not read (format 1,
    or a newer one), so the app can tell "state from another version" from
    corruption. The version is not authenticated: the code may lead only to
    re-linking, never to a weaker check. Everything else stays
    `PM_CRYPTO_ERROR`; old blobs are still refused.
  - Review follow-up: the app caps sendable plaintext at 733,184 bytes
    ("Message size"); a restore of an unsupported sealed format surfaces as
    `CryptoStateFormatUnsupported` with its own message that asks the user
    to link the device again (still fail-closed); senders run the same
    Basic-credential check (`basic_identity`) on adds that receivers run.
  - Every client must run ABI 9 before any release. The receive-side
    commit and Welcome checks (TASK-004, TASK-005) have no version gate: an
    ABI 8 committer can still add a duplicate identity, ABI 9 receivers
    refuse that commit, and the group forks with them stalled under I33.
    Nothing is released, so there is no mixed fleet yet; before a release,
    the server or app must refuse mixed ABI versions (for example a minimum
    client version on enrollment and sync). This belongs with the release
    gates in STATE.md.
  - TASK-010, TASK-048: no protocol change here. L0's secret-keyed SAS and
    tags already stop a relay without the secret from grinding keys; the doc
    comments now state the 8-digit SAS (about 26.6 bits) and the
    leaked-secret residual. Superseded by L1-3 (ABI 18), which adds
    commit-then-reveal. See "Device linking".
  - Not closed here: which identities may hold which keys, and who may
    commit or invite (TASK-006), needs the L1 approved-device list. See
    "What L1 must provide".
- **K2 ABI8 controls (2026-10-28):** adds bounded local binary control
  operations and matching Dart bindings for protocol v3. Claim proof validates
  the native key-package identity, and source SAS confirmation records intent
  without returning an approval tag. Ordinary owned-buffer free now uses the
  existing non-elidable zero-on-drop wrapper. Controls are checked, but bundle
  streams and the durable application flow remain separate unfinished slices.
  Migration0038 adds immutable signed v3 enrollment; migration0039 adds a
  temporary ciphertext/handoff resource with durable quota-charged upload
  intents, guarded writes and retryable import ACK. These have independent
  review and full Go/race checks. See `testing/evidence/K2-abi8-controls.md`
  and `testing/evidence/K2-server-transfer.md`. Release gates remain closed.

- **K2 native preparation (2026-10-28):** sealed state format 3 adds bounded,
  typed transfer records, retaining format 2 reads. Existing ABI v7 sealing
  writes format 3; this migration is active even though public K2 transfer calls
  and the Flutter transfer flow are not wired. Internal bundle and HPKE handoff
  primitives bind both device identities and the v3 link transcript. Transfer
  retries preserve keys and import state; late approval recovery requires the
  original approval window and a durably recorded source confirmation intent.
  No MLS group cloning or release-gate change. Evidence:
  [`K2-native-state.md`](../testing/evidence/K2-native-state.md) and
  [`K2-core-primitives.md`](../testing/evidence/K2-core-primitives.md).

- **W8 (2026-10-27):** implements v2 formatted text, roster-checked mentions,
  forwarded text/attachments and role-checked pins. Plain v1 bodies still send
  as v1; every envelope keeps framing metadata `payload_version: 1`. Local
  schema 13 adds decoration/channel/hidden state, pins with durable tie order,
  local stars and conversation preferences, plus a separate pending-pin table
  for own echoes. Backup plaintext v4 reads v1-v3. The original composer draft
  travels only through a local encryption argument, so stripping markup clears
  it atomically and forwarding cannot erase a destination draft. Own pins use
  the server echo's timestamp and recheck current authority; denied commands
  are consumed. No Rust ABI, server plaintext or release-gate change. Phone
  background mention delivery remains the separate D52 prerequisite. Evidence:
  [`W8-message-actions.md`](../testing/evidence/W8-message-actions.md).

- **L0 (2026-10-26):** ABI v7 extends device-link derivation with canonical
  origin, link ID and a 16-byte client secret; output is hash32, claim MAC32,
  approval MAC32, SAS MAC prefix4. Adds a 32-byte public locator operation.
  Protocol v2 uses HKDF/HMAC-SHA256 with direction-separated keys. Migration
  0037 stores opaque tags and retires unfinished v1 links. No message payload,
  MLS group ordering or release-gate change. Independent agent design/review;
  implementation evidence in `testing/evidence/L0-device-link-v2.md`.

- **Stage 5, I33 (2026-09-24):** no ABI or payload change. Sync stops,
  without advancing the cursor, at any MLS control message it cannot apply,
  and at any application message it cannot decrypt unless the message has
  provably expired. The expired-message tombstone commits only the cursor and
  an `expired:<event>:<target>` marker. The durable recovery record lives in
  local metadata (`sync.recovery`) and holds no content or key material.
  D54 (2026-10-31, above) later passes a peer message or call signal that
  can never be decrypted.
- **Stage 5, I34 (2026-09-24):** local schema v8 adds `attempt_count`,
  `next_attempt_at`, `failure_class` and `terminal` to
  `local_mls_outbox_entries` (additive migration). Messages from one MLS
  transition are now queued with increasing `queued_at`, so they are delivered
  in the order OpenMLS produced them; before, a transition's messages shared a
  timestamp and were ordered by their random idempotency key. A rejected
  control message is kept and pauses only its conversation.
- **Stage 5, I51 (2026-09-24):** ABI v6 (additive: the four functions
  above; the v5 functions are unchanged). New groups keep message secrets for
  two past epochs so a message sent just before a commit still decrypts; this
  slightly widens the forward-secrecy window. Group creation, membership
  changes and revocation removals now queue one staged commit bundle (commit,
  one Welcome for all added devices, roster change) that the server accepts
  only on the group's current epoch; this device merges its commit only after
  acceptance and drops it after a refusal, so a lost race never forks the
  group. Application envelopes carry `mls_epoch` in `crypto_metadata` (the
  epoch is already visible in the MLS header), which the server uses to
  withhold older-epoch messages from devices that joined later.
- **Stage 5, I45 (2026-09-24):** the mobile backup plaintext is format
  version 2: it adds the decrypted history and reactions (D27) to the
  identity, MLS state and queues it already carried; version 1 still
  restores. Encryption is unchanged (chunked AES-256-GCM with a device-held
  key; the server sees only ciphertext and a recovery-token hash). Recovery
  downloads may resume from any offset the server has sent, and the
  capability is still consumed only when a transfer reaches the end.
- **Stage 1 follow-up, attachments (2026-09-25):** no ABI change. Demo
  builds now send and receive the existing `attachmentManifest` payload.
  Each entry is the attachment crypto manifest (random per-file key, nonce
  prefix, chunking, `conversation_id` and `action_id` context, file name,
  media type, plaintext size) plus the server attachment `id` and
  `ciphertext_size`. The key travels only inside the MLS message; the upload
  carries only `{version, algorithm, chunk_size}` and the envelope's
  `attachment_refs` names the blob so it expires with the message. A
  receiver drops entries whose `conversation_id` is not the message's
  conversation, checks the downloaded size before decrypting, and decrypts
  into memory; temporary ciphertext and plaintext files are deleted
  afterwards. Received manifests are stored in local history (kind
  `attachment`, same encrypted database as decrypted text) with no schema
  change.
- **Safety numbers v2 (2026-09-25):** no ABI change;
  `pm_crypto_group_safety_number` returns a new value. The transcript
  (`veritra-conversation-safety-v2`) binds the group id, the member count and
  every member device's credential and signature key, sorted, with repeated
  members refused. The epoch is no longer bound, so routine commits keep the
  number; a device that joins, leaves or changes its signing key changes it.
  The number grows from 12 to 60 digits (SHA-512 over the transcript hash,
  twelve groups of five, about 199 bits): 12 digits was about 40 bits, short
  enough to grind a device key against. Stored DM verifications now carry a
  version byte; version 1 records read as not verified rather than as a false
  "changed". Groups show the number for a live comparison and store nothing.
  Residual: first contact is still trust-on-first-use (no key transparency),
  and a change to one's own devices also changes a DM's number.
- **T49C follow-up (2026-10-23):** local schema v9 is index only:
  `local_ciphertext_envelopes (conversation_id, position)`, created with
  `CREATE INDEX IF NOT EXISTS`; no table, row, ABI or payload change. An
  upgrade now runs all its steps and the new version in one transaction.
- **T49C-3 (2026-10-23):** no schema, ABI or payload change. The cached
  conversation list and ciphertext snapshot are written incrementally: one
  transaction deletes the rows that are gone and upserts the rest, writing
  a row only when its conversation, position or payload differs. The stored
  rows are the same as after the former full rewrite.
- **W2 (2026-10-24):** local schema 10. `local_messages` and
  `local_ciphertext_envelopes` gain `expires_at` (epoch milliseconds, indexed);
  no ABI or payload change. Decrypted rows are deleted only by their own
  expiry, a cached envelope only removes itself. The upgrade backfills the
  expiry from the cached envelopes and purges what has expired, in its one
  transaction. That migration backfill is the one place expiry is taken
  from cached envelopes. Backups are format 3 from here on and carry message
  expiry with the history; only a format 1 or 2 backup is backfilled on
  restore, so a server cannot relist an envelope with a short expiry and have
  an export and restore erase decrypted history.
- **W6 (2026-10-24):** local schema 11 adds `local_drafts` and
  `local_conversation_mutes` (new tables only). No ABI change; the reaction
  payload is unchanged (`reaction` stays a string of at most 32 UTF-16 code
  units, so any single emoji fits). Server migration 0035 adds
  `muted_until`.
- **W10 (2026-10-24):** local schema 12 adds `local_messages.search_id`, the
  FTS5 table `local_message_search` and three triggers. No ABI or payload
  change. A build without FTS5 searches by scanning `local_messages`.

- **Local database upgrade failure (2026-10-23):** no schema change. An
  open that fails after the key has opened the file and a schema upgrade
  has started is reported as an upgrade failure, not `keyRejected`; a wrong
  key still fails before the upgrade and stays `keyRejected`. The upgrade
  transaction rolls back, the file and its key stay as they were, the
  failed handle is closed and a retry runs the upgrade again. SQLite
  `SQLITE_FULL` or `SQLITE_IOERR` is `upgradeStorageFull`: the recovery
  screen asks the user to free space and retry, and offers the confirmed
  reset only once a retry has failed the same way again. Any other error
  (a damaged page, a step that cannot complete) is `upgradeFailed`: a
  neutral message, Retry first and the confirmed reset at once. The reset
  quarantines the file and its key as before, so no failure leaves
  clearing app data as the only way out.
- **Backups and device transfer (2026-10-23):** platform policy, no data
  change. Android keeps `allowBackup="false"` and adds
  `dataExtractionRules` (API 31+, cloud backup and device-to-device
  transfer) and `fullBackupContent` rules (older versions) that exclude
  every app-data domain; Android 12+ transfers otherwise ignore
  `allowBackup`. On iOS each database open, before and after it, asks the
  Runner (channel `org.veritra.private_messenger/storage`) to set
  `NSURLIsExcludedFromBackupKey` on the profile directory and the existing
  database, WAL and SHM files. Before: a database this build cannot open is
  excluded too, and a new one is created in an excluded directory. The
  Runner tries every path and reports failures once, as a count; a failure
  there does not block the open.
  Defence in depth: a copied database cannot be opened without its
  device-only key. The app's own encrypted backup is unaffected. Not yet
  built or run on a device.
- **W7 and W11 designs (2026-10-24): proposed, not yet built.** The design
  for application payload version 2 is in
  [Payload v2](#proposed-not-yet-built-application-payload-v2-w7) below. It
  covers formatting, mentions, forward, pins, polls and votes, the admin
  delete reserved for C5, and the profile-key types reserved for W11. The
  profiles design is in [`designs/W11-profiles.md`](designs/W11-profiles.md).
  Neither needs an ABI change. When built, they bring local schema 10 and
  backup plaintext version 3. W11 also adds one server table and its routes.

  One change for the G25 reviewer alters the I33 policy. Today an
  application message that decrypts but fails to decode is fatal: an
  unknown type, an unknown `v`, a bad body or a context mismatch. Sync stops
  there, and the rollback in `processApplicationMessage` restores the
  ratchet, so every retry fails the same way. The sync cursor is global,
  so one malformed message from any group member stops every conversation
  on the receiving device. A DM peer can stall the call-signal path the
  same way, for up to 7 days. Under v2 (rules P1–P6):
  - once MLS decryption succeeds, the state and cursor always commit, and
    the message becomes an `unsupported` or `invalid` placeholder row;
  - placeholder rows are keyed by the sync event, not by the server's
    idempotency key;
  - the server's envelope fields are checked before decryption;
  - a bad call signal is dropped after commit;
  - unknown sync event types are skipped, unless they start with `mls.`,
    `message.` or `call.`.

  Step 0 does not stop undecryptable MLS ciphertext from halting the
  global cursor: an MLS decryption failure stays fail-closed by design, and
  a later design has to decide how to isolate it. (Decided by D54, see its
  entry above.)

  MLS-level failures keep the I33 behaviour. The precedent is D25, which
  already commits a sender-mismatched message as `unverifiable`. Step 0
  re-keys that row too.

  An independent review approved both designs with changes, now applied.

- **W8 step 0 built (2026-10-24): receive policy, P1-P6.** No schema or ABI
  change: `invalid` and `unsupported` are new values of the existing
  message `kind` column (the raw JSON of an `unsupported` row goes in
  `body`). A payload that decrypts is now always classified
  (`AppPayloadCodec.classify`), so the MLS state and cursor commit; envelope
  fields are checked before decrypt; `invalid:` and `unverifiable:` rows are
  keyed `<kind>:<syncEventId>:<envelopeId>`; bad call signals are dropped
  after commit; unknown sync events are skipped unless they start with
  `mls.`, `message.` or `call.`. Covered by `receive_policy_test.dart` (both
  stores) and `sync_recovery_test.dart`. Built as `v` 1 only; the type names
  on the wire are the Dart enum names (`callSignal`, `attachmentManifest`),
  see §2. Also: a call signal whose sender account the receiver guessed
  wrong (a caller's other device) is dropped after commit; a reaction
  applies only to a live `text` or `attachment` row (both stores); a failed
  local commit (SQLite or file error) is retried, not reported as
  undecryptable. Residual: placeholder rows set `server_message_id` to the
  envelope's ID, which the server controls; a repeat of an ID is ignored by
  the insert, so a server that reuses an envelope ID can make a later row
  for it be dropped (an availability harm, no content).

## Application payload v2 (W7/W8)

**Status:** W8 implements formatting, mentions, forwarding, pins and local
actions; full verification and D52 phone background delivery remain pending.
B3 (polls and votes, 2026-11-07) is implemented: `poll` and `poll_vote` are
on, and so is `poll_close` (D96, §5.5). W11 (profiles) and later C2/C5 remain
reserved. It needs no ABI change: Rust encrypts the
B2 (link previews, §5.8) adds the optional `link_preview` body field.
B3 (polls), W11 (profiles) and later C2/C5 remain reserved. It needs no ABI
change: Rust encrypts the
padded payload as opaque bytes, and all of this lives in
`mobile/lib/crypto/app_payload.dart`, `native_crypto_service.dart` and the
local database.

### 1. Receive policy (W8 step 0, lands before any v2 sender)

**Today's failure.** `AppPayloadCodec.decode` throws on an unknown `type`,
a `v` other than 1, extra body fields or a context mismatch.
`processApplicationMessage` then restores the previous MLS state, and sync
stops at `applicationUndecryptable`. Decoding is deterministic, so the
retry decrypts and fails again, and the event never passes. The sync
cursor is **global** (`local_sync_states` is a single row), so one bad
message stops every conversation on the device, not just its own. Any
member of any group can do this to every other member.

Step 0 makes these six rules (P1–P6) true. W8 step 0 is safe to build only
once all six hold:

- **P1. Classification after a successful decrypt is total.** Once
  `device.decrypt` returns plaintext, any exception raised before the
  storage write produces an `invalid` row, and the MLS state and cursor
  commit with it. That covers decoding, validation and building the
  effects. Today's examples:
  - `callSignal` inside a message envelope (the type check at
    `native_crypto_service.dart` ~683, and `messageEffectsFor` ~903,
    which throws for `callSignal`);
  - any other type on the call path (~506).

  Only storage and IO errors from the commit itself roll back and retry.
  They are transient, and the ratchet is restored with them.
- **P2. Check the server's envelope fields before decrypting.** Run
  `_validateContext` (`app_payload.dart`) on the server-supplied
  `conversation_id`, `sender_device_id` and `idempotency_key`
  **before** `device.decrypt`. A failure is a malformed sync event under
  I33: fail closed, with no ratchet step used. Afterwards, P1 compares the
  decrypted context against these already-valid fields.
- **P3. Key placeholder rows by the event, not the claimed sender.** An
  `invalid` row's key is `invalid:<syncEventId>:<envelopeId>`, never
  `messageKey(envelope…)`. The envelope's `idempotency_key` is
  unauthenticated when the payload context fails, so the server could
  otherwise pick a key that collides with a real message and block it,
  because inserts are insert-or-ignore. The existing D25 `unverifiable`
  row has the same flaw: step 0 keys it as
  `unverifiable:<syncEventId>:<envelopeId>`.
  An `unsupported` row keeps `messageKey()`. Its context check passed, so
  its `action_id` is authenticated.
- **P4. Call signals.** In `processCallSignal`, once decryption succeeds,
  the MLS state and cursor commit. A bad or unexpected payload is dropped,
  with no row and no signal. Today the rollback lets a DM peer stall the
  other side's sync until the call expires and the tombstone rule applies
  (up to 7 days).
- **P5. Unknown sync events are decided by prefix.**
  - An unknown type starting with `mls.`, `message.` or `call.` stops sync
    (fail closed).
  - Any other unknown type is skipped, and the cursor moves past it.

  Such events carry no ciphertext and only ask for a refresh, so skipping
  one cannot hide content. The rule applies in both places that throw
  `unsupportedEvent` today:
  - the `_knownProjectionEvent` gate in the sync loop (`app_state.dart`
    ~3043);
  - the final throw in `_refreshProjectionForSyncEvent` (~3245).

  W11's `profile.updated` depends on this rule.
- **P6. Unknown top-level keys are not rejected at `v` ≥ 2.** Only the
  frozen keys below are required.

**Outcomes.** All rows but `undecryptable` follow a successful decrypt;
those checks run in this order:

| Outcome | When | Row key | Row body | Shown as |
|---|---|---|---|---|
| `invalid` | Framing or UTF-8/JSON broken; `v` not an integer ≥ 1; a context field missing or not equal to the envelope's (`conversation_id`, `sender_device_id`, `action_id`, and `channel_id` per §2); a **known** type at a supported version whose required fields fail validation; or any other exception before the storage write (P1) | `invalid:<syncEventId>:<envelopeId>` | none | A warning: "A message could not be read". Never content |
| `unsupported` | Context matches, and either `v` is above the highest version this app supports, or `v` is supported but the type is one this app does not know or has not turned on (reserved types, §4). The step-0 app supports only v1, so any `v: 2` there is `unsupported` | `messageKey()` | The inner JSON exactly as decrypted (≤ 64 KiB, encrypted local database only), so that a later app version can reinterpret it. Reprocessing is a later decision; storing it now is the only chance, because MLS cannot decrypt the message twice | "This message needs a newer version of Veritra", or **nothing** when the payload has `hidden: true` |
| known | Everything validates | `messageKey()` | As today | As today |
| `undecryptable` (D54) | MLS decryption failed twice with `operationFailed`, `nativePanic` or `invalidOutput`, the committed group restored before the retry and again after it; stored with kind `invalid` | `undecryptable:<syncEventId>:<envelopeId>` | none | "Couldn't unlock this message". Never content. A call signal gets no row |

**Rules for `unsupported` rows** (S3):

- Each one expires with its envelope (W2), like any message.
- The same author's `delete` may target one, which clears its raw JSON.
- Delete for me clears it too.
- W10 search never indexes the raw JSON.

**What stays fail-closed under I33:**

- MLS decryption failures outside D54: any native error kind other than
  `operationFailed`, `nativePanic` and `invalidOutput` (such as
  `invalidArgument` or `unknown`);
- control messages (Welcome and commits), including an own-device commit
  with no queued bundle while the group is not yet past its epoch (a
  fork);
- sync events that are missing or malformed (including P2);
- unknown `mls.`, `message.` and `call.` events (P5);
- the expired-message tombstone rule.

`invalid` and `unsupported` rows never produce effects. Neither counts as
a target, apart from the `delete` exception above, and neither raises a
notification.

**Frozen for every future version:**

- **Framing:** `VAP1`, a big-endian u32 length, the JSON, then random
  padding to a 256-byte bucket, at most 64 KiB in all.
- **Required top-level keys:** `v`, `type`, `conversation_id`,
  `sender_device_id`, `action_id`, `body`.
- **Optional top-level keys, frozen in meaning:**
  - `channel_id` (§2): context-checked against the envelope.
  - `hidden` (S2): `true` marks a control message that changes state
    rather than adding a bubble. An app that classifies the message as
    `unsupported` stores the row without showing it. Senders set it on
    `pin`, `poll_vote`, `poll_close`, `admin_delete`, `profile_key` and
    `group_profile_key`. It is ignored when the type is known.
  - `frank` (C6): the franking key, always the last member in one fixed
    byte form, `v` ≥ 2 only. Rules in [Franking v1](#franking-v1-c6).

Step 0 already reads `channel_id` and `hidden`. Any `v` ≥ 2 may add
top-level keys (P6) and body fields. A v3 must keep the frozen keys, so
that a v2 app can still check context and classify a v3 message as
`unsupported`.

### 2. Versions and compatibility

- **Inner `v`.** A sender writes `v: 1` when the payload is a v1 type
  (`text`, `reply`, `edit`, `delete`, `reaction`, `attachmentManifest`,
  `callSignal`) whose body uses only v1 fields, and the conversation is
  not `community_shared`. Anything else is `v: 2`. A pre-W8 app can then
  still read plain messages from a W8 app. This rule does not reach W11's
  profile-key sidecars (§5.7): after W11 most posts are v2.
- **Decoding v1.** A v2 app decodes `v: 1` exactly as today: the closed
  type set, exact field counts, and exactly the six top-level keys. A known
  type that fails those checks, or a v1 payload with other top-level keys,
  is `invalid`. A v1 type this app does not know is `unsupported` (see the
  outcomes table in §1).
- **Wire type names.** The string in `type` is the Dart enum name today,
  not snake_case. The sender and receiver code is unchanged, and this table
  is the contract:

  | Type | Wire string |
  |---|---|
  | text | `text` |
  | reply | `reply` |
  | edit | `edit` |
  | delete | `delete` |
  | reaction | `reaction` |
  | attachment manifest | `attachmentManifest` |
  | call signal | `callSignal` |

  Settled by B3 for the poll types: `poll` and `poll_vote`, the snake_case
  names this document uses (the code maps `AppPayloadType.pollVote` to
  `poll_vote` through `wireName`). Existing strings never change. Still open
  for `admin_delete`, `profile_key` and the rest: use the same snake_case
  convention, or decide otherwise, before any sender ships. Changing an
  existing wire string would break every device.
- **Decoding v2 and later.**
  - Required fields are validated.
  - **Unknown body fields and unknown top-level keys are ignored** (P6),
    so a later additive field needs no version bump.
  - A change that must not be ignored needs a new type or a new `v`.
- **`channel_id` (S1, for C0).** v2 adds an optional top-level
  `channel_id`.
  - In a conversation of kind `community_shared` (C0) it is **required**
    and must equal the envelope's `channel_id`.
  - In any other conversation it must be **absent**.
  - Either mismatch is `invalid`.
- **Server-visible metadata.** `crypto_metadata.payload_version` stays the
  constant **1** on every envelope. It names the `VAP1` framing, not the
  inner `v` or the highest version the app supports. It must **never**
  mirror the inner `v`; otherwise the server could tell polls, pins or
  formatted text from plain text. Receivers ignore it, and the server does
  not read it (checked: `server/internal` never parses it).
- **Old apps.** No release exists, so there is no deployed base.
  - A pre-step-0 demo build receiving any `v: 2` payload still stops at
    that message. Update every demo device when step 0 lands.
  - From step 0 on, every newer version degrades to `unsupported` rows,
    hidden ones included.
  - No capability negotiation is needed.

### 3. Referencing a target message

A target is named by its local history key,
`<sender_device_id>:<action_id>` (D22). That is the key in
`messageKey()`, today 85 characters: `dev_` plus 32 hex, `:`, then 48
hex. The field name is `message_id`, for every type that names a target,
as in v1, with a limit of 128 characters. A server message ID is never
used, so the server cannot redirect an action.

A receiver applies a targeted effect only when a row exists with:

1. `key == message_id`;
2. the same `conversation_id` as the action. In a `community_shared`
   conversation the `channel_id` must match too. The conversation check
   is **new**: `ReactionEffect` checks no conversation today, and edits
   and deletes check only the sender account. W8 adds the check to every
   targeted effect, the existing ones included;
3. a kind the action allows (table in §4).
   - Today's targetable kinds are `text` and `attachment`; v2 adds `poll`.
   - `action`, `invalid`, `unsupported` and `unverifiable` rows are never
     targets. The one exception: the same author's `delete` may target an
     `unsupported` row (§1);
4. `deleted_at` null **and** `hidden_at` null.
   - A row deleted for this device only (§6) is a target for nothing here.
     A later edit therefore never writes its text back into the local
     database or the next backup.
   - Reactions, pins and votes on it are dropped on this device, not just
     hidden.
   - Other members' apps are unaffected.

If no such row exists, the effect is dropped and the action row is kept.
This happens when the target is older than this device's membership, or
has already expired (W2). Sync is in server order, and a sender can only
target a message it has already seen, so pending effects are not kept.

### 4. Type registry (v2)

"Sender" means the account authenticated by MLS (D25). "Role" means the
role in the conversation's cached roster (`ConversationMember.role`),
looked up through one authorization seam,
`ConversationAuthority.roleOf(conversationId, accountId)`. Roles come from
the server today: a hostile server could promote an account so that its
pins (and later its admin deletes) are accepted. That harms integrity
(hiding or pinning messages), not confidentiality. C4 moves roles into the
group's MLS state, and then only the seam changes. "Moderator roles"
means `owner`, `admin` and `moderator`.

**Residual until C4 (S4).** Each device reads roles, and the conversation
kind (DM, group or shared), from its cached server roster at the moment it
processes the action. Two devices whose rosters differ can therefore
disagree about whether, for example, a pin was allowed. Ordering is
deterministic: `pinned_at` and every other "time" of an effect is the
envelope's server `created_at`, and ties go by sync order. Only the role
input can differ.

| Type | v | Body (required; *optional*) | Who may send (checked by every receiver) | Effect |
|---|---|---|---|---|
| `text` | 1/2 | `text`; *`entities`*, *`mentions`*, *`forwarded`*, *`link_preview`*, *`profile_key`*, *`group_profile_key`* | Any member | Visible row, kind `text` |
| `reply` | 1/2 | `text`, `reply_to_id`; *`entities`*, *`mentions`*, *`link_preview`*, *`profile_key`*, *`group_profile_key`* | Any member | Visible row with quote; `reply_to_id` resolved with the §3 rules for display only |
| `edit` | 1/2 | `message_id`, `text`; *`entities`*, *`mentions`* | Target's author account | Replaces text, entities and mentions together. An edit **never** raises a mention alert |
| `delete` | 1 | `message_id` | Target's author account | Clears body and reactions. Kinds widen to `text`, `attachment`, `poll`, and `unsupported` (its raw JSON is cleared, §1); clearing an attachment row also drops its keys. A poll's votes and pin go with it |
| `reaction` | 1 | `message_id`, `reaction` (≤ 32 UTF-16 units, empty clears) | Any member | As today, plus the conversation check |
| `attachmentManifest` | 1/2 | `attachments` (≤ 32); *`forwarded`*, *`profile_key`*, *`group_profile_key`* | Any member | Row kind `attachment` |
| `pin` | 2 | `message_id`, `pinned` (bool); `duration_seconds` when `pinned` is true: 86400, 604800 or 2592000 | DM and group: any member (owner decision 2026-10-31; an admin-only group switch waits for C4). Community conversation/channel: moderator roles | §5.4 |
| `poll` | 2 | `question`, `options` (list of strings), `multiple_choice` (bool); *`profile_key`*, *`group_profile_key`* | Any member | Row kind `poll` (new); body holds the poll JSON |
| `poll_vote` | 2 | `message_id`, `choices` (list of option indexes; empty = retract) | Any member | §5.5 |
| `poll_close` | 2 | `message_id` | The poll's author account | §5.5 |
| `admin_delete` | 2 | `message_id` | Moderator roles; target in the same conversation, any author | **Reserved for C5:** handled as `unsupported` until C5 turns it on. Effect then: as `delete`, shown as "Removed by an admin" |
| `profile_key` | 2 | See [W11](designs/W11-profiles.md#mls-payloads) | Only the subject account's own devices | Hidden action row; the key is stored in the same transaction as the MLS state (**built**, W11) |
| `group_profile_key` | 2 | See [W11](designs/W11-profiles.md#mls-payloads) | Any member | Hidden action row; kept only for a conversation of kind `group`, and dropped when it does not open the served record (**built**, W11) |
| `callSignal` | 1 | Unchanged | Unchanged | Unchanged |
| `info_key` | 2, hidden | `subject_kind` (`community` or `channel`), `subject_id`, `key_id` (32 hex = W11 key id of `key`), `key` (canonical base64 of 32 bytes) | Any member holding the key, **only in the group that owns it**: the community shared group for the community key, the private channel's group for its key | C3: kept with the MLS state (schema 31); used only when it arrived in the owning group. Never franked, never reportable |
| `info_key_request` | 2, hidden | `subject_kind` (`community` or `channel`), `subject_id` | Any member | C3: kept so a key holder can answer; one per subject per hour |
| `info_update` | 2, hidden | `subject_kind` (`community`, `category` or `channel`), `subject_id`, `revision` (≥ 1), `key_id` (32 hex), `record_sha256` (64 lowercase hex of the blob as served) | Community and category: owner and admins; channel: any member unless admins restrict channel info (D80), all under the community shared group's C4 role state | C3: a fetched record is shown only when an announcement from an allowed editor, in the group that owns its key, matches it |
| `history_change` | 2, hidden | `r`: canonical base64 of the 143-byte compact record, or a move's 143 + `lp(close_group_id)` + 128-byte wrap | Owner and admins under the verified C4 role state (D80); only in a two-part C7 message of the channel itself | C7: a record proposal (docs/designs/C7-channel-history.md decision 3). Never franked: the envelope's `frank_commit` is 32 random bytes |
| `history_sync` | 2, hidden | `for_epoch` (u64), `channels`: `[[channel_id, base64(key_c)], ...]`, 1 to 508 entries, ids sorted bytewise and distinct, keys 32 bytes | Any member; group-level only (no `channel_id`), two-part only | C7 decision 5: body0 of the history_sync body; its slots follow body0 in the sealed body. Never franked |
| `history_sync_request` | 2, hidden | `for_epoch` (u64): the membership commit whose history_sync the sender lacks | A newcomer; group-level only, two-part only | C7 decision 5. Never franked |
| `report_key` | 2, hidden | `key`: canonical base64 of 32 bytes, the sender's own report public key; no other field | Any member (the key is the MLS sender's own); who moderates is judged when a report is sealed, against the C4 record | C6: kept as setting `c6.report_key.<group>.<sender account>` only in a group whose MLS state holds a C4 record and only from an L1-approved leaf; latest wins. Never franked, never expires, never reportable |
| `report_key_request` | 2, hidden | `accounts`: 1 to 64 distinct account ids (1 to 128 characters); no other field | Any member | C6: kept as setting `c6.report_key_request.<group>` (the sync event id) only when it names the receiver's account, under the same group and leaf rules; each named moderator's app announces again, at most once per 5 minutes per group. Sent by a member's background pass when it lacks some moderators' announcements (a new set at once, the same set weekly), never by the report flow. Never franked |
| `device_list_alert` | 2, hidden | Exactly `account_id` (1 to 128 chars), `head_version` (int ≥ 1), `list_id` (64 lowercase hex): the sender's own pinned list head | An approved device of `account_id` itself (it must equal the MLS-authenticated sender's account, and the sending leaf must be `approved` now, review M3; any other alert is a hidden row with no effect) | L2-5: sent, identified and never franked, when this device judges a leaf of its own account unapproved; goes out past the sender's own approval hold, once per conversation and own head. Receivers keep one alert per alerting device (head and list id, at most 32 per account; review M3), refetch the list past the rate limit and judge again. An alert holds while the pin does not show its device removed and either is of the same list id and older than its head, or is of another list id that still lists its device (a list restarted from a new genesis without it releases it); while any alert holds, every leaf of the account is `checking` (held, not sticky). Never expires (no sender expiry, review M2) |
| `member_leave_signed` | 2, hidden | Exactly `statement`: canonical base64 of the 70-byte leave statement (`u32 leaf_index \|\| u16 64 \|\| Ed25519 signature`) | The leaving device itself (sent after its `member_leave`, under the leave-notice mark) | C4 leave proof in the commit (ABI 24): kept as setting `c4.leave_signed.<group>.<account>` only in a record group and only from a leaf its list approves now; a committer that removes the account carries it in the commit's authenticated data, where Rust verifies it against the tree. Never franked, never expiring in effect (cleared with `c4.leave.*`) |

In a C0-layout conversation a two-part message with no `channel_id` must be
`history_sync` or `history_sync_request`, and those two never carry one;
anything else is an `invalid` row (C7). The C7 types arrive only in two
parts.

A "reserved" type has a fixed name and body now. Until its package turns
it on, a receiver treats it as `unsupported`, and a sender never sends it.

Every new effect is applied in the same transaction as the MLS state, as
today (D22, D23). An action from a sender who fails its "who may send"
check keeps its `action` row and has no effect.

### 5. Field rules

#### 5.1 Formatting: `entities`

The sender's composer turns markers into ranges and strips the markers
from the text:

| Marker | Range type |
|---|---|
| `*bold*` | `bold` |
| `_italic_` | `italic` |
| `~strike~` | `strikethrough` |
| `` `code` `` | `code` |
| ```` ```block``` ```` | `code_block` |
| `\|\|spoiler\|\|` | `spoiler` |

The wire form carries only plain text and ranges, so receivers never parse
markup:

```json
"entities": [{"type": "bold", "offset": 0, "length": 5}]
```

- `offset` and `length` are integers in UTF-16 code units of `text`. That
  is Dart's native unit and the unit of `maxAppTextLength`. Rules:
  - `offset ≥ 0`, `length ≥ 1`, `offset + length ≤ text.length`;
  - a range must not split a surrogate pair;
  - ranges of the same type must not overlap;
  - `code` and `code_block` overlap nothing;
  - other types may nest;
  - at most 256 entries.
- **Lenient by design:** an entry that breaks a rule, or has an unknown
  `type`, is dropped alone. An `entities` value that is not a list is
  ignored. Formatting never makes a message `invalid`.
- There is no link entity. Receivers detect URLs in the text locally and
  show the real URL, so link text cannot hide its target. The receiver
  never fetches a link; a preview is made by the sender (§5.8).

#### 5.2 Mentions: `mentions`

```json
"mentions": [{"account_id": "acct_…", "offset": 0, "length": 4}]
```

- The range rules are those of §5.1. `text[offset]` must be `@`. At most
  50 entries.
- A mention whose `account_id` is not in the conversation's current roster
  is dropped, and the text shows unstyled. A malformed entry is also
  dropped alone.
- The text is shown as sent. A tap opens that member.
- **Alert rule** (evaluated on the device after decryption; the server
  never learns of mentions): a `text` or `reply` raises a notification
  **even when the conversation is muted** when all of these hold:
  - a kept mention names this account;
  - the sender is not blocked;
  - the setting "Mentions in muted chats" is on (default on);
  - the message is not this account's own.

  `edit` never alerts. There is no `@all` in W8. A future boolean
  `mention_all` is reserved, for moderator roles only.
- The mobile push limit is in [Open questions](#open-questions-for-the-owner-w7).

#### 5.3 Forward: `forwarded`

```json
"forwarded": {"hops": 1}
```

- **Hops.** A forward is a **new** `text` or `attachmentManifest` payload
  in each target conversation, with a new `action_id`. The sender writes
  `min(source hops + 1, 5)`, where the source's hops count as 0 if it was
  not forwarded. A higher count would tell members more about a message's
  path than the label needs. Receivers clamp to 1..5.
- **Label.** `hops` 1–4 reads "Forwarded"; ≥ 5 reads "Forwarded many
  times".
- **Nothing links to the source:** no original sender, source
  conversation, source key or time.
  - Mentions are dropped.
  - Entities are kept.
  - A forwarded `reply` becomes a `text` without its quote.
- **Attachments.** Each one is decrypted locally, then re-encrypted with a
  **fresh key** and re-uploaded into the target conversation. Blob read
  access is per conversation, and reusing the key or ciphertext would let
  the server link the two chats by hash.
- **What can be forwarded:** `text`, `reply` and `attachment` rows. Not
  `poll`, `unsupported`, `invalid`, `unverifiable` or deleted rows.
- **Limits, enforced by the sender's UI only** (a client cannot prove
  them to others): one forward action reaches at most 5 chats, and at
  most 1 chat when the source has `hops` ≥ 5.
- **Residual (S5, for L2).** The server sees one upload per target chat,
  with the same plaintext size bucket, in the same second as the forward.
  It can link forwarded attachments by size and timing even though the
  keys and ciphertext differ. Attachment padding (manifest v2, 2026-10-31)
  widens the size to a 5% bucket, but one bucket at one moment still links
  them; send jitter belongs to L2.

#### 5.4 Pins

- **Pin and unpin.** `pinned: true` with `duration_seconds` from {1 day,
  7 days, 30 days} pins the target. `pinned: false` unpins it. Expiry
  is the pin envelope's server `created_at` plus `duration_seconds`,
  never the sender's clock, and never later than the target's own
  `expires_at` (W2).
- **Conflicts and limits.** Pins apply in sync order, and the last pin
  action for a target wins. `pinned_at` is the pin envelope's server
  `created_at`, and ties go by sync order. A conversation has at most
  **50** active pins (owner decision 2026-10-31; W7 first set 3); a
  `community_shared` conversation has at most 50 **per channel**. The 51st
  evicts the oldest by `pinned_at`. The pin bar shows about three rows and
  scrolls.
- **Expiry and deletion.** Expired pins disappear from the pin bar when
  it is drawn, and are swept when the chat opens. Deleting the target,
  for everyone or for this device only, removes its pin here.
- **Old apps.** A pin is an MLS payload, shared by every member. It is
  sent with `hidden: true`, so an older app stores it as a hidden
  `unsupported` row and shows nothing.

#### 5.5 Polls and votes (B3)

- **The poll.** `question` is 1–300 UTF-16 units; `options` has 2–12
  unique strings of 1–100 units each. An option is named by its index,
  and options never change after sending.
- **Vote validity.** A vote counts only when:
  - every index in `choices` is in range, and there are no duplicates;
  - if `multiple_choice` is false, there is at most one index;
  - the poll is not closed;
  - the target is a `poll` row in the same conversation.

  Otherwise the vote has **no effect at all**: it is not partly applied.
- **Counting.**
  - One vote per account, not per device; the last valid vote in sync
    order replaces the earlier one.
  - An empty `choices` retracts the vote.
  - Apps count the votes of accounts in the current roster.
- **Closing.** After `poll_close` from the author, later votes are
  ignored. The tally freezes at the close's position in sync order.
- **Who voted.** Every member's app can see who voted for what, because
  the vote sender is authenticated. Veritra offers **no "anonymous
  poll"**; the UI must not suggest one.
- **Size.** A poll fits well inside one payload (~5 KiB at the limits).
- **As built (B3).** `poll`, `poll_vote` and `poll_close` are on. A `poll` that
  breaks the limits is `invalid`; a `poll_vote` is checked for shape only
  (a text `message_id` of at most 128 characters, at most 12 integer
  `choices`), and range, duplicates, the single-choice rule and the target
  are checked when it is applied, so a bad vote is an action row with no
  effect (vectors 12-13). Votes are sent with `hidden: true`. A device
  applies its own vote when it sends it (it cannot decrypt its own echo), so
  if the same account votes from two devices, the two can disagree about
  which came last until a later vote. Polls cannot be reacted to, replied
  to, forwarded or pinned, and are not copied to a new device (K2 history
  and the quoted preview of a reply show the question only).
- **As built (poll close, D96).** `poll_close` is v2, sent with
  `hidden: true`, and checked for shape only (a text `message_id` of at most
  128 characters). When applied it needs a live `poll` row in the same
  conversation and channel whose sender account is the closer; otherwise it
  is an action row with no effect. It sets `closed: true` in the poll row's
  body and keeps the votes. Votes applied after it, in sync order, change
  nothing, and a second close changes nothing. A device applies its own close
  when it sends it. The bubble shows "This poll is closed." and the author
  sees a "Close poll" button while it is open. There is no reopen.

#### 5.6 Admin delete (reserved for C5)

C5 decides how roles become trusted (C4). Until then the type stays
reserved. The receiver rule is fixed now:

- the sender's role, through the seam, is a moderator role at processing
  time;
- the target passes §3;
- the effect is that of `delete`, with the row marked `removed_by_admin`.

#### 5.7 Profile-key sidecars (reserved for W11)

`text`, `reply`, `attachmentManifest` and `poll` may carry two optional
body fields:

- `"profile_key": {"key": "<base64, 32 bytes>", "key_id": "<32 hex>", "version": <int>}`.
  The sender account's current profile key, so that members who joined
  after its last `profile_key` message still learn it.
- `"group_profile_key": {"key": …, "key_id": …, "version": <int>}`. The
  conversation's group profile key. A device attaches it to its next post
  after it has processed a commit that added devices (S13).

Until W11 both are ignored, like any unknown field. The rules are in W11.

#### 5.8 Link previews: `link_preview` (B2)

The **sender's** app fetches the page and puts the result inside the
encrypted message. Receivers and the server never fetch anything, so a
link cannot be used to learn that a recipient read a message.

```json
"link_preview": {"url": "https://example.org/a", "title": "A",
                 "description": "…",
                 "thumb": {"mime": "image/png", "width": 96, "height": 54,
                           "data": "<base64>"}}
```

- **Where.** An optional body field of `text` and `reply`. A body that
  carries it is written as `v: 2`, so a v1 receiver never sees it. No new
  type, ABI, server or schema change.
- **Fields.** `url` is required. At least one of `title`, `description`
  or `thumb` must remain after cleaning, or the preview is dropped.

  | Field | Limit |
  |---|---|
  | `url` | https, default port, no credentials, an ASCII public-looking DNS name (not an IP literal, not `localhost`, `.local`, `.internal` and the like), 2,048 characters |
  | `title` / `description` | 200 / 400 UTF-16 units, after cleaning |
  | `thumb` | `image/png` only, at most 16 KiB, at most 160 × 160 px, the declared size must match the PNG header |
  | body (text and preview together) | 48 KiB of UTF-8 |

- **Receiver rules.** Lenient, like formatting: a preview that breaks a
  rule is dropped alone and the message stays valid.
  - The `url` must carry no tracking parameter and no fragment, and must
    equal, after the same tracking strip, **a link in the message text**.
    A card can therefore never describe a different site than the one the
    message names.
  - `title` and `description` lose control characters and bidirectional
    overrides, and whitespace is collapsed. A bad `thumb` is dropped alone.
  - The card shows the real host from `url` above the title. It has no tap
    target: receivers do not open or fetch the link.
- **Sender rules.**
  - A setting on this device, "Link previews": **off**, **known sites
    only** (the default: a small allow-list of reference and code-hosting
    sites, `linkPreviewAllowList`), or **all sites**. With "known sites
    only", an unknown site is never contacted.
  - Only the **first** link of the text is considered, and only if it is
    https. Tracking parameters (`utm_*`, `fbclid`, `gclid` and similar) and
    the fragment are removed before the fetch and in the sent `url`.
  - The fetch is bounded: 8 seconds in all; one page of at most 256 KiB;
    at most 3 redirects, and **every hop** must again be https, a
    public-looking host, and inside the setting; the response must be
    `text/html`; no cookies, no referrer, a generic user agent. The
    resolved addresses must all be public unicast, so a pasted link cannot
    probe the sender's own network.
  - The page is parsed with the `html` package for `og:title`,
    `og:description`, `og:image` and the Twitter equivalents, falling back
    to `<title>` and `<meta name="description">`.
  - The picture is fetched under the same rules (at most 384 KiB), then
    decoded, scaled to at most 128 px and **re-encoded as PNG**, which drops
    all metadata; it must fit in 16 KiB (96 and 64 px are tried next). It
    travels inline inside the encrypted payload, not as an attachment, so
    the server sees no extra upload.
  - If the body is over budget, the thumbnail goes first, then the whole
    preview. A fetch or encoding failure sends the message without a
    preview. Sending never fails because of a preview.
  - The fetch happens before encryption and before the send queue, so a
    slow site never holds the session queue; a second tap on the same chat
    is refused until it finishes.
- **Edits and forwards.** An `edit` carries no preview and replaces the
  stored decoration, so an edit removes the card. A forward copies text and
  entities only, so it never carries one. Delete (for everyone or for me)
  clears the preview with the text.
- **Local storage.** A received preview is kept under the key `link_preview`
  of the row's existing `format_json`. No column, table, migration or
  schema number changes. The K2 history snapshot and backup writers drop
  the whole key from `format_json` (and the field itself when nothing else
  is left), so exports stay small and older readers still accept them: a
  copied or restored history shows text and formatting but no preview
  cards. The K2 snapshot reader still accepts the key and re-validates it
  against the text. The backup reader does not inspect `format_json`; a
  stored preview is checked again when a message is drawn
  (`chat_screen.dart`). Notifications and message search never read it.
- **Residuals.** (1) The site, and anyone on the path, sees the sender's
  address and that it was asked for this page, once, when the message is
  sent. (2) The address check happens before the connection; a name that
  changes its answer in between (DNS rebinding) is not caught, bounded by
  https, port 443 and the bounded read. (3) The padded size of a message
  with a thumbnail is visibly larger to the server (256-byte buckets).
  (4) The sender chooses the preview text, so it can differ from what the
  site shows; the host line is the part receivers can trust.

### 6. Local-only state (never an MLS payload, never sent to the server)

| Feature | Stored as | Notes |
|---|---|---|
| Star | `local_starred(message_key PK, starred_at)` | Removed when the target is deleted or hidden |
| Delete for me | `local_messages.hidden_at` set; body, attachment manifest, and its reactions, pin and votes cleared on this device | Any visible row, also others' messages. Later effects on it are dropped (§3). Others still see it |
| Archive chat | `local_conversation_prefs(conversation_id PK, archived_at, pinned_at)` | An archived chat stays archived when a new message arrives (owner may change, see below) |
| Pinned chats | Same table, `pinned_at` | At most 5, ordered by `pinned_at` |

None of these sync to the account's other devices. That waits for K0/K2,
which gives the account a key its own devices share. The UI says "on this
device" for star, archive and pinned chats.

### 7. Size limits

| What | Limit |
|---|---|
| Padded payload | 64 KiB, 256-byte buckets (unchanged) |
| `text` | 16,384 UTF-16 units (unchanged) |
| `entities` / `mentions` | 256 / 50 entries |
| Link preview (§5.8) | `url` 2,048; `title` 200; `description` 400; `thumb` 16 KiB PNG, 160 px; text + preview 48 KiB |
| Target key (`message_id`) | 128 characters (current keys are 85) |
| Poll | question 300; 2–12 options of ≤ 100; `choices` ≤ 12 |
| Active pins per conversation | 3 (per channel in a `community_shared` conversation) |
| Forward | 5 chats per action; 1 when `hops` ≥ 5; `hops` sent ≤ 5 |
| Pinned chats | 5 |

### 8. Local storage: schema 13, backup plaintext v4

W8's implementation uses schema 13 and backup plaintext v4 because expiry,
drafts and search had already taken schemas 10-12 and backup v3. It adds
`hidden_at`, `forward_hops`, `format_json`, `channel_id` and nullable
`sender_hidden` (null means false), plus `local_pins`, `local_starred` and
`local_conversation_prefs`. Pins also retain `applied_order` so ties keep
their sync order through backup/restore. The separate `local_pending_pins`
table stores only this device's outgoing pin commands until their first
matching server echo; it is applied/cleared in that cursor transaction.
Authority is checked again at the echo. Commands denied after demotion are
consumed without an effect. A same-device backup may retain a command with
either its queued outbox or its still-pending own action row (HTTP can
acknowledge before sync echoes). K2 history transfer must exclude this table.

B3 adds no table and no schema change. The `local_poll_votes` and
`local_poll_state` tables below were not built: a poll row's `body` holds
`{question, options, multiple_choice, votes: {account_id: [index]}}` plus
`closed: true` once the author closed it, the
vote effect rewrites it in the MLS transaction, and delete or delete for me
clears the body and so the votes. Because they are in the message body they
travel in the existing backup. The original design below also reserves
poll-close and admin-delete state, which neither W8 nor B3 creates. W11 takes a later backup number when it is implemented.

Action rows store no body, so pin, vote and close state cannot be rebuilt
from history. They are tables applied in the MLS transaction:

| Change | Detail |
|---|---|
| `local_messages`: new nullable columns | `hidden_at`, `forward_hops`, `format_json` (entities and mentions as received), `removed_by_admin`, `channel_id` (C0 shared groups), `sender_hidden` (an `unsupported` row whose payload had `hidden: true`) |
| `local_messages`: new kinds | `poll`, `unsupported`, `invalid` |
| `local_pins` | `conversation_id`, `channel_id` (nullable), `target_key`, `pinned_by_account_id`, `pinned_at`, `expires_at`; PK (`conversation_id`, `target_key`) |
| `local_poll_votes` | `poll_key`, `voter_account_id`, `choices_json`, `updated_at`; PK (`poll_key`, `voter_account_id`) |
| `local_poll_state` | `poll_key` PK, `closed_at` |
| New local-only tables | `local_starred`, `local_conversation_prefs` (§6) |

- **The upgrade** is additive and runs in one transaction, as schema 9
  did.
- **Backup plaintext v4** adds the implemented W8 state; v1-v3 still restore.
  Poll state and profile-key tables remain reserved. Their implementing
  packages take the next backup number rather than reusing v4.

### 9. Server

No change for W7. The type stays inside the ciphertext, and every
envelope's metadata looks the same (§2). These actions never use the
legacy server routes (`/messages/{id}/reactions`, envelope edit and
delete).

C2 must decide one thing: in an admins-only chat the server can refuse a
non-admin's envelopes, but it cannot see their type. It can refuse all of
them, which also stops reactions and votes, or none of them.

### 10. Test vectors

Every vector below is the **inner JSON**. The test frames it: `VAP1`, the
u32 length, the bytes, zero padding to 256. It decodes with this context:

- `<C>` = `conv_11111111111111111111111111111111`
- `<D>` = `dev_22222222222222222222222222222222`
- `<A>` = `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` (48 a)
- `<T>` = `dev_33333333333333333333333333333333:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`
  (a `text` row in `<C>` by `acct_33333333333333333333333333333333`)
- `<T2>` = the same key shape, for a row in another conversation
- `<P>` = `<D>:<A>`, the poll from vector 11; votes on it use other action
  IDs
- `<M>` = `acct_44444444444444444444444444444444`, a member of `<C>`

`H` is the four-key head, followed by `"type":…`:
`"v":2,"conversation_id":"<C>","sender_device_id":"<D>","action_id":"<A>"`.

Decoding:

1. `{"v":1,"type":"text","conversation_id":"<C>","sender_device_id":"<D>","action_id":"<A>","body":{"text":"hi"}}`
   gives `text` "hi": v1 is unchanged.
2. `{H,"type":"text","body":{"text":"hello world","entities":[{"type":"bold","offset":0,"length":5}]}}`
   gives `text` with bold over "hello".
3. `{H,"type":"text","body":{"text":"hi","entities":[{"type":"bold","offset":1,"length":5}]}}`
   gives `text` "hi" with **no** entity (out of bounds).
4. `{H,"type":"text","body":{"text":"😀x","entities":[{"type":"italic","offset":1,"length":1}]}}`
   gives `text`, entity dropped (it splits a surrogate pair).
5. `{H,"type":"text","body":{"text":"@bo hi","mentions":[{"account_id":"<M>","offset":0,"length":3}]}}`
   gives `text` with a mention of `<M>`. On `<M>`'s device it alerts while
   the chat is muted.
6. `{H,"type":"edit","body":{"message_id":"<T>","text":"@bo hi","mentions":[{"account_id":"<M>","offset":0,"length":3}]}}`,
   with the sender account `acct_3333…`: the text is replaced and
   **nothing** alerts. With any other sender account, nothing changes.
7. `{H,"type":"text","body":{"text":"fwd","forwarded":{"hops":5}}}` gives
   `text` labelled "Forwarded many times".
8. `{H,"type":"pin","hidden":true,"body":{"message_id":"<T>","pinned":true,"duration_seconds":604800}}`
   from a `member` in a group: an `action` row, **no pin**.
9. Vector 8 from an `admin`: pinned, expiring at envelope `created_at` + 7 d.
10. `{H,"type":"pin","body":{"message_id":"<T>","pinned":true,"duration_seconds":12345}}`
    gives `invalid` (a known type with a required field out of range).
11. `{H,"type":"poll","body":{"question":"Lunch?","options":["Pizza","Sushi"],"multiple_choice":false}}`
    gives a `poll` row.
12. `{H,"type":"poll_vote","body":{"message_id":"<P>","choices":[2]}}`
    gives an `action` row and no vote (index out of range).
13. `{H,"type":"poll_vote","body":{"message_id":"<P>","choices":[0,1]}}`
    on this single-choice poll: no vote.
14. `{"v":1,"type":"reaction","conversation_id":"<C>","sender_device_id":"<D>","action_id":"<A>","body":{"message_id":"<T2>","reaction":"👍"}}`
    gives an `action` row and **no reaction** (a cross-conversation
    target; it fails on today's code). It is v1, so step 0 can run it.
15. `{H,"type":"sticker","body":{"id":"x"}}` gives `unsupported`. The
    cursor advances, and the JSON is kept.
16. Vector 1 with `"v":3` gives `unsupported`.
17. Vector 1 with `"conversation_id":"conv_99999999999999999999999999999999"`
    gives `invalid`, keyed `invalid:<syncEventId>:<envelopeId>`. The cursor
    advances, and no text is kept.
18. Vector 1 with `"body":{"text":"hi","extra":1}` gives `invalid` (v1
    stays strict).
19. `{H,"type":"text","body":{"text":"hi","future_field":true}}` gives
    `text` "hi" (v2 ignores unknown fields).
20. `{H,"type":"admin_delete","hidden":true,"body":{"message_id":"<T>"}}`
    before C5 gives a hidden `unsupported` row.
21. Vector 8 on a step-0 app gives a hidden `unsupported` row: nothing is
    shown, and the cursor advances.
22. `{H,"type":"text","channel_id":"chan_66666666666666666666666666666666","body":{"text":"hi"}}`
    in a group that is not `community_shared` gives `invalid`.
23. In a `community_shared` conversation whose envelope `channel_id` is
    `chan_6666…`: vector 22 gives `text` "hi". The same vector with
    `chan_7777…` gives `invalid`, and so does vector 1 (no `channel_id`).
24. `{"v":1,"type":"callSignal",…,"body":{"signal":{}}}` arriving in a
    **message** envelope gives `invalid` (P1). The cursor advances.
25. `{H,"type":"text","future_top":1,"body":{"text":"hi"}}` gives `text`
    "hi" (P6).
26. An envelope whose server `sender_device_id` is 200 characters stops
    sync **before** decryption (P2). The MLS state is unchanged.
27. On the call path, a decrypted `text` payload is dropped (P4). The MLS
    state and cursor commit, with no row and no signal.
28. An `invalid` message whose envelope `idempotency_key` equals the
    action ID of an existing row `<D>:<X>` leaves that row untouched (P3).
29. `{H,"type":"text","body":{"text":"see https://example.org/a?utm_source=x","link_preview":{"url":"https://example.org/a","title":"A"}}}`
    gives `text` with a card for `example.org`. The same vector without
    `link_preview` is a `v: 1` payload on the wire (B2).
30. Vector 29 with `"url":"https://bank.example/"` gives `text` and **no**
    card (the URL is not a link of the text).
31. Vector 29 with `"url":"http://example.org/a"`, with
    `"url":"https://example.org/a#x"` or with
    `"url":"https://example.org/a?utm_source=x"` gives `text` and no card.
32. Vector 29 with a `thumb` whose declared size differs from its PNG
    header, or whose data is over 16 KiB, gives a card without the image.

Encoding: `encode()` writes the keys in this order:

- top level: `v`, `type`, `conversation_id`, `sender_device_id`,
  `action_id`, then `channel_id` and `hidden` when present, then `body`;
- body: the order of the "Body" column in §4.

Dart's `jsonEncode` keeps insertion order, so vectors 1, 2, 7, 8 and 11
(with `type` moved second) are also byte-exact encode vectors. The test
asserts the bytes between the header and the padding.

Also required:

- **sync tests:** an `unsupported` and an `invalid` message each commit
  the MLS state and the cursor, and the next message decrypts, in the
  same conversation and in another one (the cursor is global);
- **projection events:** an unknown projection event (`profile.updated`)
  is skipped, and an unknown `mls.x`, `message.x` or `call.x` event stops
  sync, through both gates (P5);
- **`native_outbox_test.dart` (I31) covers every new type end to end.**

### 11. Build order

1. **W8 step 0:** It can land alone, and is safe to build once P1–P6 hold.
   It covers:
   - P1–P6 (§1);
   - the re-keyed `unverifiable` row;
   - reading `channel_id` and `hidden`;
   - the conversation check on targets (§3);
   - the `invalid` and `unsupported` kinds;
   - vectors 1, 14–18, 21 and 24–28.
2. **W8:** the v2 codec, formatting, mentions and the mute alert,
   forward, pins, star, delete for me, archive, pinned chats, schema 10,
   backup v3.
3. **B3:** turn on `poll`, `poll_vote` and `poll_close`.
4. **W11:** turn on `profile_key`, `group_profile_key` and the sidecar.
5. **C5:** turn on `admin_delete` after C4 has settled roles.

### Open questions for the owner (W7)

1. **Mentions in muted chats on phones.**
   - The server drops push wakes for muted chats
     (`push_wake_store.go`), so on Android and iOS a mention in a muted
     chat shows only at the next sync. Desktop syncs all the time, so W8's
     Windows target is not affected.
   - Options:
     - (a) Muted chats still get generic, silent wakes. The device then
       decides locally. It costs battery, and the server learns nothing
       new.
     - (b) Accept the delay on phones.
   - Making the server mention-aware is ruled out: it would leak who
     mentions whom.
   - Recommendation: (a), for mobile only.
2. **Archive.** Does an archived chat return to the list when a message
   arrives? This design keeps it archived, as WhatsApp does today.
3. **Limits.** 3 pins per chat and 5 pinned chats (WhatsApp uses 3 and 3;
   Telegram uses more). They are easy to change.
4. **Who may pin in groups.** This design allows moderator roles only.
   The alternative is any member until C4 adds a permission switch.

## Franking v1 (C6)

**Status:** the byte rules, the commitment (ABI 12) and the vector are
built, and since C6 wiring steps 2 and 3 (2026-11-07) every message the app
sends carries `frank` and `frank_commit`, every receiver checks them, and
the server stores `frank_commit` write-once and routes sealed reports. D95
(local schema 19) then added what a receiver keeps to report a message, the
sealed envelope id, per-owner copies and pinned owner keys (see "D95"
below). No ABI or payload version change. Design:
[`C6-reports-franking.md`](designs/C6-reports-franking.md).

**Canonical bytes `P`.** `P` is the inner JSON (the bytes between the `VAP1`
header and the padding) exactly as the sender's encoder writes it **without**
`frank`: `AppPayloadCodec.encode`'s key order (§10), at `v: 2`. `P` is never
rebuilt by re-serializing parsed JSON, so it is the same bytes for the
sender, every receiver and a verifier, whatever JSON library each uses.

**Wire form.** The wire inner JSON is `P` without its final `}`, then
exactly

```text
,"frank":{"k":"<kf as standard base64 with padding, 44 characters>"}}
```

so `frank` is always the last top-level member, with no whitespace and one
member `k`.

- **Version.** A franked payload is `v: 2` (or later). A v1 receiver checks
  exactly six top-level keys, so `frank` on `v: 1` is `invalid` everywhere.
  This overrides the §2 rule that writes `v: 1` for plain v1 types once
  franking is turned on.
- **Reserved key.** `frank` joins `channel_id` and `hidden` as an optional
  top-level key frozen in meaning (§1). A `frank` inside `body` is not it.
  A v2 app older than the receive check ignores `frank` (P6) and so
  accepts a message whose commitment is wrong; no such release exists.
- **Receive rule** (`splitFrank`, `mobile/lib/crypto/franking.dart`). If the
  parsed object has no top-level `frank`, the payload is unfranked. If it
  has one, the bytes must end in the exact form above, the key must decode
  to 32 bytes and re-encode to the same 44 characters, and `P` (the bytes
  before the suffix, plus `}`) must parse on its own as an object with no
  top-level `frank`. Then the suffix is necessarily the last top-level
  member and `P` holds everything else. Anything else is malformed: the
  payload is `invalid` (§1), never treated as unfranked.
- **Commitment.** `c = pm_crypto_frank_commit(kf, conversation_id,
  sender_device_id, action_id, P)` with the envelope's context fields,
  already checked against `P` (P2). It rides beside the ciphertext as the
  top-level envelope field `frank_commit` (32 bytes, standard base64 in
  JSON), never inside `crypto_metadata`.

**Vector** (`testing/vectors/c6-franking-v1.json`): the §10 context
`<C>`, `<D>`, `<A>`, `kf` = 32 bytes of `0x07`, and

- `P` = `{"v":2,"type":"text","conversation_id":"<C>","sender_device_id":"<D>","action_id":"<A>","body":{"text":"hi"}}`;
- wire = `P` without the final `}` + `,"frank":{"k":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="}}`;
- `c` = `e84e3e81d8ac625060a472b2c311b19fc56e8472c80ffa0b304e63930158980a`.

`encodeFranked` writes exactly `P` and the wire bytes; `splitFrank` returns
`P` and `kf` from the wire bytes; the Go reference, Rust and Dart all compute
`c`.

### What is wired (C6 steps 2 and 3)

**Send** (`NativeCryptoService.encryptPayload`). Every message type on the
message path (text, reply, edit, delete, reaction, attachment manifest, pin)
is written with `encodeFranked`, with a fresh 32-byte `kf` per message. The
commitment is computed over `P` with the new envelope's `conversation_id`,
this device's id and the action id (the idempotency key), and sent as
`frank_commit`. Call signals are not envelopes and are not franked. A hidden
type (a pin) is franked like any other, so the server cannot tell it apart.

**Receive rule** (G2, G5). The commitment context is the envelope's own
fields, which `classify` has just matched against the decrypted payload,
never fields read out of the payload again.

| Payload | Envelope `frank_commit` | Result |
|---|---|---|
| malformed `frank` | any | `invalid` |
| franked | missing, not 32 bytes, or not the recomputed value | `invalid` |
| franked | matches | accepted |
| no `frank` member | present or absent | accepted, unreportable |

The last row is the G5 decision: an unfranked payload is accepted, because
older apps and the C7 hidden types (design item 9, which send 32 random
bytes as `frank_commit` without a `frank` member) must keep working while
apps roll out. The cost: a sender that wants to be unreportable can send
unfranked. Refusing unfranked payloads, with the hidden types exempt after
decoding, is a switch (`FrankingPolicy.acceptUnfranked`, D95), off for now:
see "D95". A native failure while recomputing becomes an `invalid` row, never
a stuck sync (P1).

**Server** (migration 0047). `message_envelopes.frank_commit` is its own
nullable `BLOB` column, 32 bytes or `NULL`, accepted as a top-level request
field and returned on every read path and in sync events. A trigger aborts
any later change to it (G3), and an idempotent retry must repeat it. The
legacy in-place edit route refuses franked rows, since it would leave the
commitment stale; the app sends edits as new envelopes. The server never
checks the commitment.

**Report aad** (G4, v2 since D95). A sealed report's HPKE aad is

```text
"veritra-c6-report-aad-v2" || lp(inbox_kind) || lp(inbox_id) ||
lp(recipient public key) || lp(conversation_id) || lp(report_id) ||
lp(reporter_account_id)
```

with `lp` a big-endian u32 length, `inbox_kind` `instance_owner` or
`community`, and `inbox_id` the owner's account id (one inbox and one sealed
copy per instance owner) or, for a community, one moderator's inbox
`<community id>:<account id>` (one sealed copy per moderator, 2026-11-11).
`report_id` is chosen by the
reporter's app, once per report, and is the same in every copy, so the
copies belong together and a copy cannot be replayed as another report. The
envelope id is not in the aad: it is sealed inside the body. Including the
recipient key binds a key rotation too. `franking.ReportAAD` (Go) and
`reportAad` (Dart) build it; the shared vector is
`testing/vectors/c6-report-aad-v2.json`. The reporter seals with it and the
recipient's app rebuilds it from the server's report row, so a report sealed
for other values does not open.

**Server routes** (D95). `PUT /api/v1/reports/inbox-keys/instance` (an
owner publishes their own report public key; recent sign-in required),
`GET /api/v1/reports/inbox?conversation_id=` (the inbox kind and its
`recipients`: one `{inbox_id, public_key, key_rev}` per instance owner that
has published a key, or the community's moderator key), `POST /api/v1/reports`
with `{conversation_id, report_id, copies: [{inbox_id, key_rev,
recipient_public_key, sealed}]}`, `GET /api/v1/reports?inbox=` (the caller's
own copies; for `instance_owner` the inbox is the caller) and `DELETE
/api/v1/reports/{id}` (dismiss the caller's own copy). The server picks the
inbox from the conversation kind (a community channel to that community's
moderator inbox, a DM or group to the instance owners), requires a member
reporter, and requires the copies to be exactly the current recipients (for
a community: a non-empty subset of them, see the C6 design's "Community
moderator inbox"), each at the current `key_rev` and key (a revision alone repeats if the publishing
owner is deleted). It checks that each `sealed` starts with `VRP1` and fits
the Rust core's bounds, never opens one, never logs one, keeps at most 20
reports a day per reporter (one report is all its copies) and 2000 copies per
inbox, and stores one row per copy with no column for the message. The
retention sweeper deletes every copy 90 days after it was filed; a recipient
dismissing its copy removes just that copy.

`GET /api/v1/reports/{id}/envelope?envelope_id=` (step 4) answers the
recipient of copy `{id}`, and nobody else (anyone else gets 404), with what
the server recorded for that envelope: `{envelope_id, conversation_id,
sender_account_id, sender_device_id, frank_commit?, created_at}`. The
envelope must belong to the conversation the copy was filed about. It is the
one place the server learns an envelope id: at review time, from the
recipient, for one report they chose to check. It writes and logs nothing.
The app recomputes the commitment from the revealed message and compares it
with `frank_commit`, the recorded sender device and the conversation
(condition G1).

`GET /api/v1/reports/inbox-keys/instance` (step 4) returns the calling owner's
own current report key `{inbox_id, public_key, key_rev, updated_at}` (404 when
none is published, 403 for a non-owner), so a device that lost a race to
another device shows the key reporters actually see. Local schema 27 (C6)
adds `local_filed_reports (origin, account_id, message_key, filed_at)`, ids
only, so a message is reported once per account and server; it is cleared
with the pinned report keys on a full wipe. No ABI or payload change.

**Not wired.** (1) Built 2026-11-11: one key and one sealed copy per
community moderator, chosen by the reporter's app from the verified role
record (C4); no shared community seed (C6 design, "Community moderator
inbox"). (2) The report screens,
the call that builds a report from a stored reveal and posts it (the pieces
are built: `ReportBody`, `sealReportCopies`, `ReportKeyPins`), the owner's
own report seed storage and key publication, and the "verified against what
the server recorded" label (build step 4). (3) Verification by an owner: with
the envelope id sealed, the server no longer snapshots the sender, commitment
and time when a report is filed, and an owner who learns the envelope id only
after opening a copy has no route to fetch the envelope's metadata without
telling the server the id then. That route, and what a report shows once the
envelope is gone, are open (owner question, `testing/evidence/C6-wiring.md`).

**Duplicate JSON keys (G6)** do not apply yet: the only verifier is the Dart
app, which reads `P` as the exact bytes it received and recomputes over
those bytes. A second implementation that parses JSON before verifying must
reject duplicate keys first.

### D95: what a receiver keeps, sealed envelope id, pinned keys

Owner decision D95 (2026-11-07): unfranked payloads are accepted until every
sender runs the franking build, then refused; reports are kept until
dismissed or 90 days; the instance owners' report key is pinned in the app;
one sealed copy per owner (as C5); the `envelope_id` is sealed inside the
report and never sent in clear; the error-contract version stays 1 for added
codes.

**Local schema 19** (C6 only; `encrypted_database.dart`, `frank_reveals_sql.dart`).
Two tables, created by raw SQL and added in the same transaction as the
version number by the 18 to 19 upgrade (new tables only; no existing row
changes, and a message received before the upgrade has no reveal and cannot
be reported):

- `local_frank_reveals(message_key PRIMARY KEY REFERENCES local_messages(key)
  ON DELETE CASCADE, conversation_id, envelope_id, frank_key (32 bytes),
  payload (1 byte to 64 KiB), stored_at)`. `message_key` is
  `<sender_device_id>:<action_id>`. `payload` is the exact `P` the
  commitment covers. It is written in the transaction that consumes the MLS
  message (`MlsStateTransition.frankReveals`), only for a message row that is
  live after that transition; an edit, reaction, delete, invalid row or a
  message that arrived already expired writes nothing, and a reveal the table
  would refuse is skipped, never a failure of the commit (P1). `P` holds the
  message text, so a reveal is removed with the message: the row cascade
  covers purge, expiry and history reset, and a trigger covers the two cases
  where the row stays as a tombstone (delete for everyone sets `deleted_at`,
  hide sets `hidden_at`). Sign-out keeps the database, a different identity
  and a full reset clear it. It is never part of a backup, a history snapshot,
  a K2 transfer or a log. An edit keeps the reveal of the original message
  (design item 4); an edit's own `frank` is not stored.
- `local_report_key_pins(origin, owner_account_id, public_key (32 bytes),
  key_rev, pinned_at, PRIMARY KEY (origin, owner_account_id))`: see below.
  An identity change keeps it (it belongs to the server's owners); a full
  reset drops it.

**Sealed envelope id and per-owner copies.** The body sealed in each copy
(`ReportBody`, `report_body.dart`) is JSON `{v: 1, envelope_id,
conversation_id, sender_device_id, action_id, payload (base64 P), frank_key
(base64 kf)}`; `decode` refuses any other field set, a bad length or base64.
The reporter makes one `report_id`, seals the same body once to each pinned
owner key with that owner's aad (`sealReportCopies`), and posts the copies. A
recipient opens its copy with its own seed and the aad rebuilt from the row,
recomputes the commitment over `payload` with `frank_key` and the body's
context, and checks it against the commitment the server holds for
`envelope_id`. Dedupe by message (the old `UNIQUE (reporter, envelope_id)`)
moves to the reporter's app: the server dedupes only by `report_id`. The
server cannot check that the message exists, carries a commitment or is not
the reporter's own; the recipient does, against the revealed body.

**Pinned owner keys** (`report_key_pins.dart`). The server lists each owner's
report key; the app seals only to keys that equal their pin
(`ReportKeyPins.requirePinned`). Nothing is pinned silently: a pin is made
only by an explicit `ReportKeyPins.pin` after the person saw
`reportKeyFingerprint(key)`. A key the server changes is `changed` and
refused until pinned again, a key for an owner never pinned is `unpinned`
and refused, and a pinned owner the server omits is reported as
`missing`. The owner keys L2-3 pins on first use are proof recipients for
sealed-message tags only, kept apart (`owner_proof_pins.dart`, owner
decision 2026-11-12, "Keep reports manual"; "Franking a sealed message"),
and never reach a report; a pin made here also counts as a proof
recipient.

**Unfranked switch** (`FrankingPolicy`, `app_payload.dart`, passed to
`NativeCryptoService`). `acceptUnfranked` is true today. With false, a
payload without `frank` is `invalid`, except a hidden payload this app does
not understand (the C7 hidden types of design item 9, which are never
franked, exempt after decoding), or a payload whose type is in
`FrankingPolicy.unfrankedPayloadTypes` (`history_change`, `history_sync`,
`history_sync_request`, compared with `AppPayloadType.name`). Today those
decode as unsupported hidden payloads; **when C7 (#128) makes them known
types its merge must keep that set in step with the enum names**, or flipping
the switch would turn every history-control message into an invalid row. The
switch is one constructor argument; the decision to flip it is the owner's,
once no old sender is left.

## Group role state (C4)

**2026-11-11 review follow-up:** local schema **36** persists device-local
governance observations in the encrypted database, atomically with accepted
MLS transitions and outgoing application messages. It records the owner,
`ownerRev`, last locally observed owner activity, election opening revision
and first-seen time. Restarts preserve these waits; backups and history
transfers exclude them. Group deletion and crypto/identity replacement drop
them. The storage effect accepts only an already authenticated transition;
the receivers now feed it ("C4 app wiring"). No ABI or server migration
number is used by C4's remaining work; the ABI 20 carrier and release gates
are unchanged.

Built: the record codec (Dart), the crypto carrier (ABI 20, change log) and
the app wiring ("C4 app wiring" below). Design:
`docs/designs/C4-custom-roles.md` (built-in roles only, D80). Rules engine:
`mobile/lib/core/roles/governance.dart`.

**Why it exists.** Apps must not trust the server-reported role (D80), and
no MLS data names one: leaves carry Basic credentials with account and
device ids only, the group context carries no Veritra extension, and the
creator cannot be proven to a joiner. So the server's four built-in roles
are also kept in a signed record that the group's members agree on. It
replaces the proposed `governance` application payload for custom roles,
which is withdrawn.

**Carrier.** A GroupContext extension of type `0xF0C4` (private-use range;
proposed), listed in every leaf's capabilities and in the group's required
capabilities. It changes only through a commit carrying one
GroupContextExtensions proposal with this extension alone, so MLS orders
every change and a Welcome gives a joiner the current state. The creator
writes the genesis record (itself as owner, nothing else) at group creation.
Groups and a community's shared group carry it; a private channel's group
does not, and is judged against the shared group's record (C0).

**Format, version 2** (big-endian, canonical; any other byte string is
invalid). Version 1 was documented but no build ever wrote it, so it is
withdrawn and refused. Code: `mobile/lib/core/roles/governance_codec.dart`,
vector `testing/vectors/c4-governance-record-v2.json`.

```
u8  version = 2
u64 rev
u64 owner_rev                                  never above rev
u8  flags            bit 0 admins_only_posting, bit 1 election present,
                     bit 2 timeouts present (C5, below); rest zero
u16 owner_len || owner                         0 = no owner
u16 admin_count     { u16 len || account || u64 since_rev || u8 admin_flags }*
                                               admin_flags bit 0: elector; rest zero
u16 moderator_count { u16 len || account }*
u16 channel_count   { u16 len || channel_id }* announcement channels
u16 joined_count    { u16 len || account || u64 rev }*
if flags bit 1:
  u64 opened                                   never above rev
  u16 electorate_count { u16 len || account }* at least one
  u16 vote_count       { u16 len || voter || u16 len || candidate }*
if flags bit 2:
  u16 timeout_count    { u16 len || account || u64 epoch || u64 from_ms || u64 until_ms }*
                                               at least one ("C5 timeouts in the record")
```

Every list is sorted by the UTF-8 bytes of its key with no duplicates; ids
are 1 to 255 bytes of UTF-8 that round-trip (no byte-order mark); numbers
use 63 bits (the high bit is zero); the owner is in no role list (admins, moderators; `joined` and the
electorate may name it) and no account is both admin and moderator; every elector is an admin; `since_rev`,
`joined` revs and `opened` are at most `rev`; ids must round-trip through UTF-8 (no lone surrogates); every voter is in the
electorate; at most 500 channels; at most 256 KiB in all; nothing follows
the last field. A record that does not decode, or a version this app does
not know, makes the commit invalid (sync stops under I33); it is never
guessed at. The codec checks shape only: whether a change is allowed is
`validateCommit`.

**Carrier rules (Rust, ABI 20).** A record is 1 to 256 KiB of bytes Rust
never decodes. A commit carries at most one GroupContextExtensions proposal,
by value, from the committer. Its extension list must be the group's current
list in the same order, every extension byte for byte the same except the
`0xF0C4` data, which must change and stay 1 to 256 KiB. A group without a
record never gains one by proposal, and no proposal can drop it or change
the required capabilities. A Welcome whose context carries a record without
requiring `0xF0C4`, or a record of the wrong size, is refused. The producer
(`stage_commit_with_record`) runs the same check on its own staged commit
and clears it on failure. Anything else is refused before Dart sees it.

**ABI 20 calls and formats.** All integers big-endian; `lp` is a `u16`
length then the bytes.

- `pm_crypto_group_create_with_roles(handle, group_id, record)`: the
  genesis (`encodeGovernance(GovernanceState.genesis(creator))`).
  `pm_crypto_group_create` stays for a private channel's group.
- `pm_crypto_group_stage_commit_with_roles(handle, group_id, changes,
  record, out_commit, out_welcome, out_epoch)`: a change list (version 2
  only, so every add names its L1 signing key; it may hold no adds and no
  removes, then the commit is the role change alone) plus the record
  proposal. Merged or cleared like any staged commit.
- `pm_crypto_group_stage_incoming_commit(handle, group_id, commit,
  out_review)`: phase one. The review is `u8 format = 1 | u8 flags (1
  removed, 2 added, 4 removed self, 8 record proposal, 16 record before
  present, 32 record after present) | u64 new_epoch | committer lp(account)
  lp(device) [32] key | u16 n_added { lp(account) lp(device) [32] key }* |
  u16 n { lp(account) }* (roster before) | u16 n { lp(account) }* (roster
  after) | u32 len || record before | u32 len || record after` (length 0
  when absent). Rosters are accounts, distinct and sorted by bytes: an
  account stays while any of its devices stays. The committer comes from
  the MLS tree, never a server label. **This does not prove who it is**:
  a member can add a leaf with another account's id under its own key
  (L1 never refuses a commit for a list reason), so `validateCommit` may
  trust the committer or the rosters only for devices the L1 list approves
  (account, device and key from the review); an unapproved added leaf must
  not count as a roster member or as a committer. Wiring prerequisite.
  `pm_crypto_device_seal_changes` refuses (`InvalidState`) while any staged
  incoming commit is held: a seal in that window would persist the used-up
  ratchet step and lose the commit for good. Merge or discard first; after a
  discard restore the committed state, never seal.
- `pm_crypto_group_merge_incoming_commit(handle, group_id, commit, ...)`:
  phase two, with the outputs of `pm_crypto_group_l1_process_commit`
  (flags, epoch, C7 root, added pairs, committer pair). `commit` must be the
  staged bytes and the group still on the epoch they were staged on, or
  nothing changes and the commit stays held. The C7 root is derived only
  here. A commit removing this device drops its group store.
- `pm_crypto_group_discard_incoming_commit(handle, group_id,
  out_was_held)`: Dart refused it; the group is untouched. The app then
  restores its committed state (the ratchet step is used up) and sync stops
  on that commit under I33.
- `pm_crypto_group_role_state(handle, group_id, out_state)`: `u8 format = 1
  | u8 flags (1 record present) | u16 n { lp(account) }* | u32 len ||
  record`, after a join or a restore.

**Receiving a commit.** Rust stages it and hands Dart the committer
account, the account roster before and after, and the record before and
after (the record before, when the commit carries no proposal). Dart merges
only if `validateCommit` accepts:

- Accounts whose last device the commit removes are pruned first
  (`removeAccount`): their role, elector flag, `joined` entry and votes go.
  The owner is never pruned (D81): it stays owner even out of the roster, and
  nobody inherits. An election with nobody from its snapshot left in the
  roster is cleared. `rev` is kept (`requiredRecord` computes all of this
  for committers and receivers alike). A record equal to that result is valid from
  any committer; a removal that leaves a departed account named is invalid.
  An add must stamp `joined` and an owner commit must clear an open election;
  each rewrites the record at `rev` + 1. Neither
  moves `owner_rev`, and `requiredRecord` never stamps it. A bare owner
  commit (self-update, reconcile, revocation) carries no record.
  Record format v2 carries: `electors` (the per-admin "owner
  chose this admin" flag), `election` (none, or `{opened, electorate,
  votes}`), `joined` (account to the `rev` of its first device's add) and
  `owner_rev` (a `u64`, genesis 0).
  Owner decision 2026-11-07 (C4 doc, "The owner's last role decision"):
  `owner_rev` is the `rev` of the owner's last role decision, and receivers
  use it in place of a clock the phone cannot check. An owner commit moves it
  to its own `rev` only when the owner itself changes `owner`, `admins`,
  `moderators`, `electors` or a posting field; a won election or claim sets it
  to its own `rev`; any other commit must keep it, and it never exceeds
  `rev`. A D82 election (no elector in the roster) snapshots only admins
  whose `since_rev` is at or before it. Claims are not gated by it.
  Residuals: a deliberate owner role or posting decision made after a rogue
  admin's promotions makes them old enough; and, until C1 has removal
  proofs, a server that forces out every elector leaves one owner-era admin
  as a snapshot of one that wins at once. Both are in the C4 doc.
- Any other difference is a change by the committer, checked by
  `validateTransition` against the pruned record: `rev` + 1; everything
  named is in the roster after the commit; role changes as on the server
  (moderator or above; target strictly below the actor; new role at most
  the actor's); stepping down is free; only the owner transfers ownership,
  and only to a current admin, or a won election sets it (D81, D82); posting fields need admin or above; a new
  admin's `since_rev` is the new `rev`, and an admin's stays unchanged.

The check does not judge whether a removal was allowed; that is C1/C5's
receiver check on the commit.

**Sending a commit.** Every path that stages a commit (D68 reconcile,
revocation removals, device replacement, role changes) computes the pruned
record for its own commit, carries it as the proposal when it differs, and
runs `validateCommit` on the result before staging. In the app (ABI 20,
not wired yet) these are, in `mobile/lib/crypto/native_crypto_service.dart`:
`initializeConversation` (`createGroup` becomes `createGroupWithRoles` for
groups and a community's shared group; its first add stamps `joined`, so it
carries a record too), `stageMembershipChange` (D68 reconcile, re-adds and
device replacement) and `createRevocationCommit` (revocation removals), all
through the one `_stage` helper, which then calls `stageCommitWithRoles`
whenever `requiredRecord` (or a role change) differs from the current
record; role changes and the owner's election cancel are new producers of
the same call. `stageSelfUpdate` stays bare. On the receive side,
`processMlsMessageBounded`'s `commit` case moves from `processCommit` to
`stageIncomingCommit`, `validateCommit`, then `mergeIncomingCommit` or
`discardIncomingCommit`. Whether a DM's group carries a record is open. Producers are wired
before or with the receiver check, or the first kick of an admin stops
every receiver's sync. The owner's self-update stays path-only
(`stage_self_update` in `mls.rs` refuses any proposal): it carries no
record, so it never moves `owner_rev`. It cannot cancel an election either, and
receivers refuse an owner commit that leaves one open, so while an election is
open the owner's app sends the cancel (a commit with the record) first.

### C4 app wiring (2026-11-11)

What the app now does with the ABI 20 carrier. Code:
`mobile/lib/crypto/native_crypto_service.dart` (producers, receiver,
`stageRoleChange`), `mobile/lib/core/app_state_roles.dart` (actions, leave
proof, owner cancel), `mobile/lib/core/roles/governance.dart`
(`removalNeedsProof`).

**Which groups carry a record.** A group (`kind = group`) and a
community's shared group are created with `createGroupWithRoles` and the
genesis record (the creator owns it). The kind is the one the creating app
asked the server for, held locally while the group is made. A DM carries no
record (two people have no roles; decision for the open question above), and
a private channel's group carries none (it is judged by the shared group's
record). Groups made before this keep no record and no verified roles.

**Producers.** Every staged commit (first add, reconcile, re-add, device
replacement, revocation) computes `requiredRecord` for itself and, when it
differs from the current record, stages it with `stageCommitWithRoles`
after running `validateCommit` on it. Role commands (`GovernanceCommands`:
set role, electors, posting, transfer, open, vote, close) are role-only
commits through the same call. The owner's periodic self-update, while an
election is open, is replaced by the cancel (a path-only update carries no
record and receivers refuse an owner commit that leaves an election open).
A bundle that carries a record is marked `role_change: true`; the server
(`CreateMLSCommitBundle`) does not count such a commit as a self-update, so
it is neither rate-limited as one nor held behind a pending removal. The
flag is unverifiable, like `added` and `removed`; receivers judge the record.
So that the flag is no way around the self-update interval, a role-only
bundle (role_change, adding and removing no one) has its own interval: one
per device and conversation per `MLSRoleChangeInterval` (one minute,
`conversation_mls_devices.last_role_change_at`, migration 0087), refused
with the self-update limit's 429 and Retry-After. A role change is one
commit a person makes (a grant, a vote, a claim, a cancel), so the interval
costs it nothing; a server role is not checked, because plain members make
legitimate role commits (votes, the claim) and server roles can differ from
the record.

**Receiving.** Every remote commit is staged (`stageIncomingCommit`),
judged, then merged (`mergeIncomingCommit`) or discarded. A discard is
followed by restoring the committed state, and the conversation pauses on
that commit (`GovernanceRefusedException`, an invalid control message under
I33). In a record group the judgment is:

1. Both records decode; a record never appears or disappears; committer and
   rosters are UTF-8 account ids.
2. `validateCommit(prev, next, committer, before, after)` on the review's
   own data. Its inputs come only from MLS: no L1 verdict, server role or
   clock enters it, so every device reaches the same answer.
3. **L1 gate.** When the commit changes the record beyond `requiredRecord`
   (a role decision), is an owner commit cancelling an election, or is
   justified as a kick (below), the committer's leaf must be `approved` by
   its account's L1 list. `checking` (the list cannot be read now) retries
   the commit later; anything else holds it (*held commits*, below). This
   narrows D94 ("a commit
   is never refused for a list reason") for these commits only: an
   unapproved leaf can carry any account's id (ABI 20 review note), so it
   must never act with that account's role. Other commits keep D94.
4. **Removal proofs.** For each account the commit drops from the roster
   and that `removalNeedsProof` (admin, moderator, elector, in an open
   election's electorate, a voter or a voted-for candidate; never the owner,
   never a plain member), one of these must hold, else the commit is
   held (below):
   - *kick*: the approved committer `mayActOn` the account under the record
     before the commit;
   - *leave*: this device holds the account's own `member_leave` from this
     group (below);
   - *revocation*: every leaf of the account in the tree is `removed` by
     the account's own L1 list (a list read failure retries later).

Producers apply the same test to their own removals and leave out those
they cannot prove; the server keeps them pending for a device that can (the
kicker, or any member once the proof or the list arrives).

**Held commits** (review fix, 2026-11-11). Steps 3 and 4 depend on
evidence a device may not have *yet*: a newcomer's Welcome deletes every
leave proof and the server never serves it the pre-join `member_leave`, and
a pin fetched less than `minForcedRefresh` ago may not know a device linked
since. Refusing such a commit paused the conversation for good while every
other member had merged it. Such a commit is now *held*, never refused:
`GovernanceHeldException` (`committer_unapproved`, `removal_unproven`)
pauses only that conversation as `SyncFailureKind.governanceHeld`, the chat
says it is waiting for a confirmation, and sync replays it by itself
(`heldRetryDelay`: one minute, doubling per hold, at most six hours; any
other pause still waits for the user). A replay applies the same events in
order from the same committed state, so the commit merges once the list
approves the leaf or the proof is held, and nothing is merged unverified or
skipped. Leaving the conversation stays offered. Residuals: a commit from a
leaf its list has `removed` (a phone replaced after it committed, seen by a
member that was offline) stays held, because L1 list rows carry no removal
version that could order the removal against the commit (decision B keeps
such a leaf from acting with its role); and a newcomer holds an honest
leave-proven removal for good when the leaver sent no signed statement (an
older build) or its leaf changed since (*leave proof in the commit*,
below, built at ABI 24, carries it in the commit otherwise). The step-3
`checking` case still stalls device sync as a transient error, as before.

**`member_leave`** (app payload v2, hidden, never franked, never reported:
`{"epoch": n}`). A governing member's app sends it to the record group
before it asks the server to leave, and waits until the server holds it.
Receivers keep it only in a record group and only when `epoch` equals the
epoch MLS authenticated for the message, in the setting
`c4.leave.<group>.<account>`, written with the message's transition. It is
deleted when its removal merges, when the account is added again, and for
every current member on a Welcome. The owner cannot leave (D81): the app
refuses until it has transferred. Since ABI 24 the app then sends
`member_leave_signed`, the signed statement a committer carries in the
removal for members that join later (*leave proof in the commit*, below).

*Leave notice* (review fix, 2026-11-11). The proof goes through the
server's posting checks, so a moderator in an admins-only group, a voter in
an announcement channel, or a timed-out or slow-moded member could not
leave. The envelope now carries the clear metadata mark `"c4_leave": true`
(`leaveNoticeMetadataKey`, server `EnvelopeLeaveNoticeKey`), and the server
exempts a marked envelope from C2, the C5 timeout and slow mode
(`server/internal/storage/leave_notice.go`), only: in a record group (kind
`group` outside a community, or a community's shared conversation); with no
attachments, reply, thread or franking commitment; and at most four
per sender account and membership per hour (one leave sends two, the
`member_leave` and, since ABI 24, the `member_leave_signed` after it, so a
leave that did not go through can be tried again at once; four since
round 7, two before; `leave_notice_limited`, 429 with Retry-After counted
from the oldest notice in the window). The mark is unverifiable, so receivers turn any marked
envelope whose payload is not a leave proof into an invalid row: a
marked post never shows. The check runs before the payload is handled
(review L1): a marked payload of a type this app does not know is kept
only when the sender marked it hidden (a newer build's leave proof);
a visible one is an invalid row too. In a shared group the envelope still names a
channel, because C0 routing requires one there (only a C7 group-level body
of a history_sync size may name none); the exemption makes the channel's
rules irrelevant to it. The server learns that an envelope is a leave
notice; it already learns of the leave itself moments later.

**Observations.** Accepted commits, Welcomes and application messages in a
record group update `local_governance_observations` (schema 36) in the same
transaction. Only an approved leaf of the owner counts as owner activity.
Owner posts in a private channel's group do not count (their record is the
shared group's), which can only make a challenge happen sooner; the owner's
app cancels it.

**Owner cancel.** On each self-update pass the owner's app schedules, for
each record group with an open election, one cancel after a random delay
of up to 24 hours; it sends it only if the election is still open.

**Using the record.** `AppState.governanceOf` maps a community channel to
its shared group. `roleOf`, `mayPost`, `canCreateChannel`, the C2 drop and
the C3 info checks read the record first, the server's role only where
there is none. Granting a role or transferring ownership commits the record
and then updates the server's row, so the server's own route checks follow
it; the two may still disagree (the record wins in every app). A posting
switch and a new announcement channel are written to the record too.

**C5 moderator delete.** The W7 `delete` payload is unchanged on the wire. A
receiver applies a `delete` to another account's message only when the
record it holds for the conversation (a channel: its shared group's) makes
the authenticated sender a moderator or above that outranks the message's
sender (`mayActOn`); the effect carries the set of accounts the deleter does
not outrank (`DeleteMessageEffect.moderatorProtects`) and the store checks
the target's sender against it. Without a record only the author's own
delete applies, as before. A moderator delete whose target has not arrived
yet is deferred with its reach (`DeferredHistoryEffect.protects`, written
in the local deferred-effects journal only when set; a journal entry from
before has none and stays the author's own), and applies when the target
arrives if its sender is not protected. In a
community with C7 the app also calls the server's history hide, which
checks the server's moderator role.

**Owner decision B (2026-11-11): a removed leaf has no role.** A leaf whose
device its own account's L1 list marks `removed` (a stolen or replaced
phone that is still in the tree) keeps the ordinary handling of its
messages but never acts with its account's role: its `delete` is the
author's own only (`messageEffectsFor(senderActsWithRole: false)`), its C3
`info_key` and `info_update` are ignored (an `info_key_request` is not a
role action), its post where posting is restricted is dropped
(`shouldDropRestrictedPost(senderRemoved: true)`), its pin uses no
community role, and its `member_leave` is no leave proof (review M1: a
stolen phone could otherwise post a valid proof and strip its governing
account; only a leaf whose verdict is `approved` sets
`c4.leave.<group>.<account>`). Role-record commits already required an `approved`
committer (step 3) and are held otherwise; C5 timeouts and C2 powers in the
record are record changes, so the same rule covers them.

**Residuals.**
- A plain member's forced removal needs no proof; it moves only `joined`,
  which orders the no-admin claim.
- An account deleted without sending `member_leave` (or a server removal
  of a governing account nobody can prove) stays in the tree: its removal
  stays pending and the D68 send hold in that group does not release.
- A server role that differs from the record (for example a member added
  at a role, which the record does not grant) yields kicks no receiver
  accepts; they stay pending until the role is also set in the record.
- Server succession (moving the server's owner row after a won election) is
  built (docs/designs/C4-custom-roles.md, "Server succession"; migration
  0087). The server cannot verify an election, so it moves its owner row
  only when the owner has been quiet in the group or community for 37 days
  by its own clock (UTC days of envelopes and commits) and a majority of
  the current admins asked for the same admin after that activity; with no
  admins, only the longest-serving member may claim it for itself, and an
  ask from the owner is a transfer. Residuals: a colluding admin majority
  can move the row after 37 days of silence (the record, which apps use,
  does not follow); a large or inactive admin set may never reach quorum;
  apps never read that row for roles.

**Using it.** C2: a post is accepted where `mayPost` holds, and posting is
restricted where this record or the server says so. C1/C5: `mayActOn`. A
group without the extension (demo groups made before it) has no verified
roles: every account is a member to the app.

### C5 timeouts in the record (2026-11-11)

The server refuses a timed-out member's envelopes, edits and reactions
(`memberships.timeout_until`, community scope), but a server can be wrong
or hostile, and before this the apps showed whatever it delivered. A
timeout is now also in the verified C4 record of the community's shared
group, and receiving apps judge each post by it the way the server decides.

**Format.** Record version 2, flags bit 2 (`_flagTimeouts`); a record
without timeouts is byte for byte as before. When the bit is set the
record ends with:

```
u16 timeout_count (at least 1) { u16 len || account || u64 epoch || u64 from_ms || u64 until_ms }*
```

sorted by account like every list; every timed-out account is in the MLS
roster; `from_ms < until_ms` and `until_ms - from_ms` at most 28 days
(`maxTimeoutMillis`, the server's `domain.MaxTimeout`). `from_ms` and
`until_ms` are the server's clock (its `timeout_until` and that minus the
length, Unix milliseconds); `epoch` is the MLS epoch the setting commit
produces. Vectors: `testing/vectors/c4-governance-record-v2.json`
(`with_timeouts`, `timeouts_flag_without_body`,
`timeouts_flag_with_empty_list`; the unknown-flag vector now uses bit 3).

**Rules** (`validateTransition`). Setting, replacing or lifting a timeout
needs a moderator or above who outranks the member under the record before
the commit (`mayActOn`; never oneself, never the owner); a set entry must
name the epoch the commit produces (`GovernanceCommands(epoch:)`,
`validateCommit(epoch:)`, else `badShape`); a removal prunes the leaver's
entry (`requiredRecord`); a win or claim leaves timeouts unchanged. Only
rev moves; `owner_rev` does not.

**App.** `timeoutCommunityMember` sets the server's timeout first (its
answer gives `timeout_until`), then commits the record entry to the shared
group; a lift commits the record first, then the server.

**Receiving** (`shouldDropTimedOutPost`, `mobile/lib/core/roles/timeout_verdict.dart`).
For a text, reply, attachment, poll, edit, reaction, poll vote, poll close
or pin (`timeoutRefusedTypes`; control payloads and `member_leave` are
never judged) from an account with an entry, the post is judged at
`min(server time, this device's receive time + 1 hour)`: hidden (a hidden
action row, like the C2 drop) if that is inside `[from, until)`; shown at
or after `until`; and before `from` hidden only when the post's
authenticated MLS epoch (record group only) is at or after the entry's
epoch, so a server cannot backdate a post sent after the timeout began.

**Residuals.** A server can hold a timed-out post back until the timeout
has ended and deliver it then; a post in the last hour of a timeout may
show (the clock tolerance); a receiving clock more than an hour slow can
hide an honest post sent just after the end; a post sent at an older epoch
by a sender that had not merged the timeout commit is judged by time only
(bounded by OpenMLS's two past epochs); a private channel's posts are judged
by time only (their group carries no record). Builds older than this refuse
a record with timeouts (unknown flag bit) and their sync of that group
stops until they update.

### C4 leave proof in the commit (owner-approved 2026-11-11; built at crypto ABI 24)

**Problem.** A governing member's departure is proven by its own
`member_leave`, which only the members of that moment hold. A newcomer
never has it (the Welcome deletes proofs; the server withholds pre-join
events, which it could not decrypt anyway), so an honest leave-proven
removal committed after it joined was held for good on its device (held
commits, above). The fix is that the proof travels in the commit.

**Options weighed.**
- *SelfRemove proposal by reference* (RFC 9420 extension; OpenMLS 0.9.2
  `leave_group_via_self_remove`). Ruled out twice: OpenMLS refuses it under
  the pure-ciphertext wire policy Veritra uses
  (`LeaveGroupError::CannotSelfRemoveWithPureCiphertext`, `membership.rs`),
  so it would go out as a PublicMessage; and a proposal by reference must
  be committed in its own epoch, so a leave sent before the newcomer joined
  could never be referenced by the commit that removes the leaver.
- *A field in the C4 record.* Encrypted, but every older build refuses a
  record with an unknown flag bit, and the record is Dart-encoded and
  opaque to Rust, where the signature must be checked.
- *Signed leave bytes in the commit's authenticated data* (chosen).
  OpenMLS 0.9.2 sets it for the next outgoing message (`MlsGroup::set_aad`,
  reset after each staged commit) and gives it on receipt
  (`ProcessedMessage::aad`). Older builds never read it, so they behave
  exactly as now.

**What the server learns.** A PrivateMessage's `authenticated_data` is not
encrypted: the server sees the statements (a signature by the leaver's leaf
key over the group id, the leaf index and the leaf's HPKE key). It learns
that this leaf consented to leaving, which it already knows from the leave
request it served, and which leaf index the leaver had. It is stored as
part of the commit bytes and never logged. *Length leak:* the AAD sits
outside MLS's padding of the encrypted content, so the commit's length
shows how many statements it carries (70 bytes each, plus 5); a reader of
the commit bytes (the server, or anyone who sees them in transit) learns
the count without the signatures. The commit's removals are already
visible to the server as pending changes, so this tells it nothing new
about who leaves.

**Statement (v1).** Signed in Rust (`pm_crypto_c4_sign_leave`) by the
leaver's device with its leaf signature key, RFC 9420
`SignWithLabel(sig_key, "VeritraC4Leave1", LeaveTBS)`: Ed25519 over
`SignContent = VL("MLS 1.0 VeritraC4Leave1") || VL(LeaveTBS)`.

```
struct {
  opaque group_id<V>;
  uint32 leaf_index;              // the leaver's leaf now
  HPKEPublicKey encryption_key;   // the leaver's leaf encryption key now (opaque<V>)
} LeaveTBS;

statement = u32 leaf_index || u16 64 || signature        (70 bytes)
```

Binding the leaf's encryption key, not only its signature key, stops a
replay and bounds the statement's life: the device credential (and so the
signature key) survives a leave and re-add, but a re-add makes a new leaf
with a new encryption key, and so does any update path (a self-update, or
any commit this device makes). A statement is therefore valid only until
the leaf changes. The design's `epoch` field is dropped (review 2026-11-11,
item 2): the encryption-key binding already ends a statement when the leaf
changes, and an epoch could only be checked against "not after now", which
adds nothing. `SignContent` starts with the varint 0x17, which no raw
message the device credential key signs starts with (C7, the L1 device
list, the enrollment proof, the K2 hand-off and the device-link v3
enrollment proof each begin with an ASCII `veritra-...` domain), and its
label is none of RFC 9420's (`leave_proof_tests.rs` lists them; a new raw
signing site joins that list).

**Carrier.** The leaver sends it in a new hidden payload type
`member_leave_signed` (`{"statement": canonical base64 of the 70 bytes}`,
exactly that key), right after the existing `member_leave` has reached the
server (whose decoder refuses any extra key, so the statement cannot ride in
it; older receivers store the new type as a hidden unsupported row). It is
best effort: the leave goes on if it cannot be sent. Both carry the
leave-notice mark (`leaveNoticePayloadTypes`); the server's limit is two
marked envelopes per sender and membership per hour, and Retry-After is
counted from the oldest one in the window (`checkLeaveNoticeTx`).
Receivers keep it only in a record group and only from a leaf its list
approves now (as `member_leave`, review M1), in the setting
`c4.leave_signed.<group>.<account>`, written with the message's
transition, and cleared wherever `c4.leave.<group>.<account>` is (the
removal merges, the account is added again, a Welcome).

**Committer.** A commit that removes devices of accounts whose statements
this device holds goes through `pm_crypto_group_stage_commit_proven`
(record optional; the `VCL1` list, at most one statement per leaf):

```
"VCL1" || u8 count (1..16) || statement*    (leaf indices distinct)
```

Rust keeps only the statements whose leaf the commit removes and that
verify against the tree before the commit; with none left the commit has no
AAD. A malformed list is `PM_CRYPTO_INVALID_ARGUMENT` before anything is
staged, and the app then stages without it. OpenMLS clears the AAD after
each staged commit (`CommitBuilder::stage_commit`, `reset_aad`), and a
padded Welcome (L2-1) stages up to seven times, so the AAD is set inside
every stage attempt and cleared again after the last. After staging the
sender reads its commit back: the PrivateMessage's AAD must be the chosen
bytes and every statement in it must verify, or the commit is cleared.

**Verification (Rust, phase one).** `stage_incoming_commit` reads the AAD
before taking the content; when it is a well-formed `VCL1` list, each
statement whose leaf the commit removes is checked against the tree
*before* the commit (that leaf's encryption key, the group id, that leaf's
signature key, `verify_strict`). The review (format 2) appends
`u16 n_proven { lp(account) lp(device) [32] key }*`, the LeafPairs that
verified. Anything malformed, another magic, a leaf not removed, or a bad
signature proves nothing and is never a refusal: the commit is judged as
without it (so held where proof is needed).

**Dart step 4.** A governing account the committer may not act on is proven
gone by its `member_leave` (as before), by its list removing every leaf (as
before), or by an in-commit statement: one proven leaf of that account that
its list approves now (`checking` retries, as for the committer). Delta from
the design's "every removed leaf": a leave comes from one device, but the
account's removal takes all its leaves, so requiring a statement from each
would fail every multi-device account; one approved leaf is what
`member_leave` already requires.

**Cancelled leave** (review item 3). Before the `member_leave` (since
round 7; before, only before the signed statement) the sending device writes
`c4.leave_signed_out.<group>`. If the leave does not go through (the server
refuses it, or the app stops before it), the next sync pass stages a
self-update in that group (`_voidCancelledLeaves`, never while a leave of
that group is in progress); the marker is cleared when a self-update of
this device merges there, or by a Welcome.

*Void window* (owner decision A, 2026-11-11). The server lets that void past
the self-update interval (`mls_self_update_limit`): an update-only commit
from a device that sent a leave notice (the `c4_leave` mark) in that
conversation within the last hour, after its own last self-update, is
admitted once (`leaveVoidExempt`, `server/internal/storage/mls_group_store.go`;
no migration). The exempt commit moves `last_self_update_at` past the
notice, so each notice buys at most one, and notices are limited to four an
hour. The server cannot tell a void from any other self-update, so this is
a budget, not a check: a member can churn a few more epochs an hour by
sending leave notices it does not follow with a leave. The app tries the
void at once and then every 10 minutes (`AppState.leaveVoidRetry`, its own
spacing, not the periodic policy's backoff), so the statement is void
within seconds of the cancel on a reachable server.

*Honest members drop the proofs* (review MEDIUM, round 7). A stored
`c4.leave.<g>.<acct>` and `c4.leave_signed.<g>.<acct>` were cleared only by
a removal, a re-add or a Welcome, so a cancelled leave left every member
holding that account's consent to be removed for as long as it stayed. Now
a member that merges a commit from one of that account's leaves its list
approves, after the proof arrived, drops both (`_judgeIncomingCommit`): the
void self-update (any commit, in fact) ends the proof on today's members,
and the self-update's new leaf ends the statement for newcomers. A leaf its
list does not approve may carry any account's id, so its commit voids
nothing. The leaver therefore sends nothing until its own MLS queue for the
group is empty (`_beforeLeavingRecordGroup` waits for a running outbox pass
and refuses with "Try again" before any notice goes out), and while it
leaves it stages no reconcile commit there. Residual: another device of the
same account that commits between the notice and the server-side leave
voids a real leave; the removal is then held until a fresh proof or a kick
by someone who may act on the account.

**ABI.** Crypto ABI 24 (the design's reserved 25, renumbered at
integration): `pm_crypto_c4_sign_leave`, `pm_crypto_group_stage_commit_proven`,
review format 2. Vectors: `testing/vectors/c4-leave-proof-v1.json`
(`LeaveTBS`, `SignContent`, signature, statement, AAD, malformed lists),
checked in Rust (`leave_proof::tests::shared_vector_matches`) and in Dart
(`mobile/test/c4_leave_proof_vector_test.dart`), and re-derived in Go with
the standard library alone (`server/internal/c4vector`, which signs the same
bytes and gets the same Ed25519 signature); the server itself never parses
it (it checks nothing here).

**Versioning.** Old builds ignore the AAD and the new payload type and judge
as before. A new receiver of an old committer's commit sees no AAD and holds
where it lacks the proof, as before. A new committer attaches every
statement it holds. A leaver on an older build sends no statement, so its
removal stays held on a newcomer. Once every supported build sends
`member_leave_signed`, the old `member_leave` can stop being sent (its own
decision).

**Residuals.** A leaver whose leaf changes after signing (a self-update, or
any commit of its own, between the statement and the removal) voids its own
statement, and since round 7 the members' `member_leave` proof with it, so
its removal is held until a fresh leave; the leaver therefore sends nothing
while its MLS queue for the group holds work (see "Cancelled leave").
A newcomer whose list cannot approve the leaver's leaf (a stale pin) holds
the removal until it can. The statement count leaks through the commit's
length (above).
