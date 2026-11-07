# L1: approved-device list

**Status: proposed (2026-11-07), not built.** A design only, against `main`
at `0073fe4`. It changes the crypto ABI, the server schema, the local schema
and the recovery flow, so it needs an independent review (AGENTS.md:
security, MLS ordering, recovery and credential decisions) and the owner's
answers to the questions at the end before any step is built.

## Summary

- **One signed chain per account.** Each account has a list of the devices
  allowed to hold its MLS leaves: pairs of device id and Ed25519 signing key
  (the MLS credential key). Every new version is signed by a device on the
  previous version, or by a key derived from the user's recovery key (RK),
  and names the hash of the previous version. Version 1 is the genesis.
- **The server only stores and relays it.** It cannot sign a version, so it
  cannot put a device on the list. It can still refuse, withhold or delay
  versions.
- **Members check the list before every MLS add,** and check every leaf
  that arrives by commit or Welcome. A device that is not on the list never
  gets a key package staged by an L1 client. If one arrives anyway, the
  receiving device applies the commit (so sync never stalls), then encrypts
  nothing more to that conversation and hides messages from that leaf until
  the leaf is gone.
- **Each device pins** the newest version it verified for every account it
  talks to, and only moves forward along the chain. A lower version, a gap,
  a fork or a new genesis never replaces a pin.
- **Recovery still works.** The list may hold a recovery public key derived
  from RK. A device enrolled by K0 recovery uses it to sign the version that
  replaces the lost devices with itself.
- **What it does not fix.** First contact is still trust-on-first-use. A
  server that withholds newer versions, or shows a made-up chain to someone
  who never saw the real one, is caught only when one of the account's own
  devices shares a group with the result. Closing that needs key
  transparency (roadmap L2).

## What L1 must provide, and where

`docs/crypto.md`, "What L1 must provide (TASK-006)", is the acceptance list.

| Requirement (crypto.md) | Where this design meets it |
|---|---|
| A trust anchor per account: the `(device_id, signing key)` pairs the account's own devices signed, verifiable without the server, with rollback protection | [List format](#list-format-vdl1), [Who may sign](#who-may-sign-what), [Pins and freshness](#pins-rollback-and-forks) |
| A check on every added leaf, update-path leaf and Welcome roster member | [Checks around MLS](#checks-around-mls) (sending adds, receiving commits, joining by Welcome); the update-path leaf rests on the [signing-key prerequisite](#prerequisite-a-leaf-never-changes-its-signing-key) |
| Authorization of the committer and of the Welcome sender | The committer and the Welcome signer are leaves, checked like any other leaf at entry; conversation roles stay with C4 |
| The expected roster for a Welcome | [Joining by Welcome](#joining-by-welcome): every roster leaf is checked against its account's list, and the roster's accounts against the conversation's participants |
| A defined result when the list is unavailable or stale | [Results](#results-when-a-list-is-missing-stale-or-in-conflict): adds and joins fail closed, with a visible state |

## Where things stand

- **Devices are server records.** Setup (`identity_store.go:131`),
  registration (`identity_store.go:197`), device link v2 approval
  (`community_store.go:357`), v3 approval (`device_link_v3_store.go:445`) and
  recovery completion (`account_recovery_store.go:495`) each insert a
  `devices` row with its `signing_key` (`0001_init.sql:25`, nullable).
  Nothing a peer can check says that the account's other devices agreed.
- **Peers add whatever the server lists.** `_reconcileMlsMembershipOnce`
  (`app_state.dart:6926`) claims key packages for every device that
  `GET /mls/pending-changes` lists and stages them. `stage_membership_commit`
  (`mls.rs:302`) checks that the key package's credential names the expected
  account and device, not which signing key it carries.
- **Receivers check shape only.** `inspect_commit` (`mls.rs:1082`) refuses
  non-Basic credentials, malformed or duplicate identities and an update
  that changes a leaf's identity. It does not check signing keys, and an
  update may change a leaf's signing key today.
- **Refusing a commit stops everything.** An MLS control message that
  cannot be applied stops sync at its event (I33), and there is one cursor
  for all conversations.
- **The server's key-package parse** (`server/internal/mlswire`) does not
  bind the credential to the enrollment signing key (bug-hunt Q-1, open).
- **L0 and K2** authenticate the link itself: the new device's signing key
  reaches the old device under a MAC keyed by the QR-only secret, and the
  old device's key reaches the new device the same way. L1 builds on that.

## The choice: a device-signed hash chain

Three shapes were weighed.

1. **A device-signed hash chain (chosen).** No key is shared between
   devices. Removing a device needs no rotation: the next version just
   leaves it out. It matches K0, which keeps devices holding nothing shared.
2. **An account identity key** held by every device (Matrix-style
   cross-signing). Peers would verify one stable key, so device changes
   would not change safety numbers. But every device holds it, so a removed
   or stolen device keeps the power to sign until the key is rotated, and a
   rotation is an identity change for every peer. K0 rejected a shared
   account key for the same reason.
3. **Key transparency** (an append-only log the server cannot fork without
   detection). It fixes first contact and withholding, which the chain does
   not. It needs auditors or gossip and is the L2 package; the chain here is
   what such a log would carry, so L1 is not wasted work.

Option 2 would be better if the owner wants stable per-account safety
numbers more than cheap revocation. Option 3 would be better now only if
first-contact attacks were in scope for this package.

## List format (VDL1)

Byte encoding as in K0: `lp(x)` is a u16 big-endian length followed by `x`;
integers are big-endian.

```
body =
  "VDL1"
  u8   format = 1
  lp(account_id)
  u64  version                1 for a genesis
  [32] prev_hash              all zero for version 1
  u64  created_at_ms          signer's clock; shown, never trusted
  u8   change                 1 genesis, 2 add, 3 remove, 4 recovery,
                              5 recovery key, 6 migration genesis
  u8   count                  1..16
  count × ( lp(device_id) | [32] signing_key )
                              sorted by device_id bytes; ids and keys unique
  u8   has_recovery           0 or 1
  [32] recovery_key           only when has_recovery = 1

statement = body | u8 signer_kind (1 device, 2 recovery key)
                 | lp(signer device_id, empty for kind 2) | [64] signature

signed message = "veritra-l1-device-list-sig-v1" | SHA-256(body)
                 | u8 signer_kind | lp(signer device_id or empty)

list_hash(v)   = SHA-256("veritra-l1-device-list-hash-v1" | body)
```

- **The chain** links bodies: `prev_hash` of version n+1 is `list_hash` of
  version n. The signature is outside the hash, so signature malleability
  cannot fork the chain.
- **The list identity** of an account is `list_hash` of its version 1. It
  stays the same for the life of the account (there is no reset; owner
  question 6).
- **Strict parsing.** A body with trailing bytes, an unsorted or repeated
  entry, a count of 0 or above 16, a device id or account id that fails the
  identity format (`encode_device_identity`), or a length over 4 KiB for the
  whole statement is refused. The server allows at most 10 devices
  (`config/limits.go:53`); the format leaves room.
- **Signatures** are Ed25519. Clients verify strictly
  (`ed25519-dalek` `verify_strict`, a direct dependency since D78). The
  server checks with Go's `crypto/ed25519` as defence in depth; the vectors
  include small-order and non-canonical cases, and the server must never
  refuse what clients accept from an honest signer.
- **No origin in the body.** Account ids are random server-made ids, peers
  keep pins per server, and a list is useless on another server. Leaving the
  origin out means a change of hostname does not break every chain.
- **No device names.** Names stay server metadata; peers do not need them.

### Signing labels

The credential key already signs under several labels. The L1 label is
disjoint from all of them.

| Signer | Label | Where |
|---|---|---|
| MLS itself | `SignWithLabel`: a varint length, then `"MLS 1.0 " ‖ label` | OpenMLS |
| Enrollment proof | `veritra-enrollment-proof-v1` | `mls.rs:209` |
| v3 link enrollment | `veritra-device-link-enrollment-v3` | `mls/link_v3.rs:187` |
| K2 hand-off | `veritra-k2-handoff-sig-v1` | `history.rs` |
| C7 (planned) | `veritra-c7-post-sig-v1`, `veritra-c7-history-v1` | C7 design, ABI section |
| **L1** | `veritra-l1-device-list-sig-v1` | this design |

Every Veritra label starts with `veritra-` and none is a prefix of another.
An MLS signed message cannot start with `veritra-`: read as a varint,
`v` (0x76) announces a 2-byte length, and the label that follows would have
to start with `MLS 1.0 `, not `ritra-`.

L1 signs through C7's planned credential-key sign entry point (a fixed
domain allowlist), with the L1 label added to that allowlist. For the L1
label Rust also parses the bytes as a VDL1 body and refuses unless the
signer field names this device and the body is canonical. Whichever of C7
and L1 lands first builds that entry point. There is no second signing
entry point.

The recovery signer is a separate key, `rk_list`, derived from RK with a
new HKDF label in the K0 hierarchy:

```
PRK (K0)
 └─ HKDF-Expand(PRK, "veritra-k0 device-list", 32) → Ed25519 seed → rk_list_pub
```

It is not `rk_auth` (the K0-R claim proof key): one key, one purpose.
`rk_list_pub` sits in the list, so the server and every peer see it. That
adds no guessing oracle beyond `rk_auth_pub`, which the server already
holds (D63).

## Who may sign what

`prev` is the version before; `entries` are the device pairs.

| Change | Signer | Entries compared with `prev` | Recovery key |
|---|---|---|---|
| 1 genesis (version 1) | the one listed device | exactly the registering device | none |
| 6 migration genesis (version 1) | a listed device | the account's devices after the user's review ([Migration](#existing-accounts)) | none |
| 2 add | a device listed in `prev` that stays listed | `prev` plus exactly one pair | unchanged |
| 3 remove | a device listed in `prev` (it may remove itself) | `prev` minus one or more; never empty | unchanged |
| 4 recovery | `prev`'s recovery key | exactly one pair | unchanged |
| 5 recovery key | a device listed in `prev` | unchanged | set, replaced or removed |

And for every version:

- `version` is `prev.version + 1`, and `prev_hash` is `list_hash(prev)`.
- **No return.** A device id or signing key that was listed in any earlier
  version and later left the list never comes back. A removed or recovered-
  away device stays out, whoever signs.
- **One key, one device.** A signing key appears under one device id in the
  whole chain.
- An added pair (kinds 2 and 4) is new to the chain.

The server applies the same rules and, on top, checks that each version
matches the request that carries it (below).

## Pins, rollback and forks

**Local state** (one local schema bump, next free at landing):

- `local_device_list_heads`: per account, the pinned version, its
  `list_hash`, the account's list identity (`list_hash` of version 1), the
  head statement, a state (`ok` or `conflict`), and when it was last checked.
- `local_device_list_keys`: per account, every pair the chain ever listed,
  with the version that added it and the version that removed it (null while
  listed). It answers "approved now", "approved once" and the no-return rule.
- `local_device_list_conflicts`: the two statements that prove a fork.
- `local_approval_holds`: per conversation, the leaves that hold it and why
  ([The approval hold](#the-approval-hold)).

None of it goes into a backup or a K2 bundle yet (see
[Other packages](#other-packages)). Like the rest of the database, it is
encrypted under the D01 key.

**Verifying.** A step from the pin to the next version is checked in Rust
(`device_list_check_step`); the no-return rule and the pin update are done in
Dart from `local_device_list_keys`, in one transaction.

- **First sight of an account** fetches the whole chain from version 1,
  verifies every step and pins the head. This is trust on first use.
- **Later fetches** ask only for versions after the pin and verify each step.
- **Before each decision** (staging an add, judging a leaf that is not
  approved in the pin) the app fetches newer versions for that account,
  at most once a minute per account unless a sync event says the list
  changed.

**Results of a fetch:**

| Seen | Result |
|---|---|
| Valid next versions | Pin moves forward |
| Nothing newer | Pin stays; it may be stale (withholding is not detectable here) |
| A malformed statement, a bad signature, a gap, a broken rule, a lower head | **Unavailable**: nothing changes, retry later. The server can always deny service, so this is not treated as proof of an attack |
| A validly signed version n+1 that differs from the pinned n+1, or a version 1 that differs from the pinned list identity | **Conflict**: both statements are kept as proof, and the account's state becomes `conflict` |

A fork needs a signature from a key on the pinned list, so the server alone
cannot make one for a pinned account: it takes a stolen device or a stolen
RK. A conflict is sticky. The user clears it only by verifying the safety
number with the contact and choosing to trust the branch the contact's
devices show (the app then re-pins from that branch's version 1).

### Results when a list is missing, stale or in conflict

| Account state | Adding its devices | Its leaves arriving by commit or Welcome |
|---|---|---|
| `ok` | Allowed for pairs approved in the pin | Approved if the pair is approved now |
| Unavailable (can't fetch or verify) | Not staged; the change waits and retries | Held as "checking" |
| Empty (no genesis yet: an account from before L1) | Not staged | Held as "checking" |
| `conflict` | Not staged | Held as "unapproved" |

Each shows a plain state on the conversation: "Checking <name>'s devices",
"Waiting for <name> to open the app", or "<name>'s device list changed in a
way that can't be verified. Compare safety numbers."

## Checks around MLS

### Prerequisite: a leaf never changes its signing key

A leaf is judged when it enters the group. That is safe only if its
identity and signing key can never change afterwards. Today `inspect_commit`
keeps the identity but lets an Update proposal or update path change the
signing key, so an approved leaf could swap its key. **L1 needs
`inspect_commit` to refuse a changed leaf signature key** (C7 decision 8
plans the same refusal). L1 is unsafe without it; whichever package lands
first builds it, and the other relies on it. A device that needs a new
signing key is linked again as a new device.

### Sending adds

Every path that stages an add (reconcile, conversation creation, re-adds)
goes through one gate:

1. Refresh the account's pin (above).
2. Look up the device's pair in the pin. Not approved now: skip that device,
   keep the change pending, and show the state above. Other devices in the
   same change still go ahead.
3. Stage with the expected signing key. `MemberAdd` gains
   `expected_signing_key`, and `stage_membership_commit` refuses a key
   package whose leaf signature key differs. That closes the gap between
   "the list says key K" and "the key package the server handed over".

Adds are also made complete: when an account joins a conversation, the
committer stages every device approved for it that is not already a leaf
(`group_members`), not only those the server lists. The server already
accepts that: an Added device must be a non-revoked device of a member
account that is not active in the roster, whether or not it is pending
(`mls_group_store.go:268`). A listed device the server gives no key package
for is retried; after
a grace period (1 hour) the conversation shows "Some of <name>'s devices
haven't joined yet". This makes it harder for a server to keep an account's
real devices out of a group so that they never see a ghost beside them.

### Receiving commits

The commit is checked for shape (`inspect_commit`, unchanged) and applied as
today. The processing call also returns the pairs of the leaves the commit
added and of the committer. Then, before the next send:

- Each added pair is judged against the pin, after a refresh.
- **Approved:** nothing happens.
- **Not approved:** the conversation gets an approval hold for that leaf.

The commit is never refused for an L1 reason. A refusal would stop all of
this device's sync (I33, one cursor) on a single bad commit, and would
leave the device behind the group with no way back. Applying keeps it in
step, and the hold keeps it from encrypting anything to the unapproved leaf.

### Joining by Welcome

After the structural checks the device joins, then reads every leaf's pair
(new `group_members` call) and judges each one. The roster's accounts are
also compared with the conversation's participants from the server. A leaf
of an account that is not a participant gets the same hold.

A Welcome is not refused for an L1 reason either: joining lets a later
commit that removes the leaf clear the hold. The committer that made the
Welcome and the signer of its GroupInfo are leaves in that roster, so they
are judged too. Whether that member may change membership at all is a
conversation-role question for C4, not L1.

### Messages from a leaf

Every received message is checked against the sender leaf's verdict,
recorded at entry:

| Sender leaf | Shown as |
|---|---|
| Approved now | Normal |
| Approved once, removed since (a removal not yet applied) | Shown, marked "sent from a device <name> removed" |
| Never approved | Hidden. A placeholder says "A message from a device that isn't approved was hidden." The text is not stored |

So a ghost never speaks as the account.

### The approval hold

The approval hold is a new kind of hold, beside D68's removal hold. It holds
a conversation while any of its leaves is not approved now. Each held leaf
has one of three reasons:

- `unapproved`: never on its account's list;
- `removed`: on the list once, but removed since;
- `checking`: not decided yet.

While held, the device sends no application message or self-update to the
conversation. It may still commit a removal.

It differs from D68 in what releases it. D68 releases on the server's
pending-changes list and roster, which a malicious server controls (the D68
residual in crypto.md). The approval hold releases only on local evidence:
after a commit, `group_members` shows no held leaf left, or a refreshed pin
now approves it. That also closes D68's residual for devices that were
removed from the list.

That is how L1 stays fail-closed without stalling:

- nothing new is encrypted to an unapproved leaf;
- nothing from it is shown as its account;
- sync goes on for every other conversation.

### A device's own account

After every commit and Welcome, a device also checks the leaves that name
its own account against its own pin. It is the authority there: it signs
that chain. If a leaf was never on the list, or was added after its device
was removed, the device holds the conversation and tells the user: "A
device you didn't approve was added to your chat with <name>." This is what
catches a server that showed a peer a stale or made-up chain, as long as one
of the account's real devices is in the group.

Telling the peers too (an MLS message carrying the account's head) is
step L1-4, below.

## Lifecycles

### First device

`POST /setup/owner` and `POST /register` take a `device_list` field: a
change-1 genesis signed by the new device. The account and device ids are
reserved before key generation, so the device can sign before the request.
The server checks that it lists exactly the reserved device with the
enrollment signing key, and inserts it in the same transaction as the device
(`identity_store.go:131`, `:197`). No account exists without a list.

### Linking a device (L0 v2 and K2 v3)

1. The old device verifies the claim tag and the typed safety code (L0).
   The new device's signing key is then authenticated by the QR-only secret.
2. The old device refreshes its own pin and signs change 2: its pin plus
   the new pair.
3. The approve request (`POST /device-links/{id}/approve`, and the v3
   approve) carries it. The server checks that the added pair is exactly the
   link's device and claimed signing key, that the signer is the approving
   device, and that the version chains from the head. It inserts the version
   in the same transaction as the device (`community_store.go:357`,
   `device_link_v3_store.go:445`). If the head moved meanwhile, it answers
   409 `device_list_conflict`. The old device refreshes, re-signs and retries
   without asking the user again; the L0 approval tag does not cover the
   list.
4. The new device gets the head with the completion. It checks:
   - the signature against the old device's key from the authenticated
     transcript;
   - that the head lists the new device's own pair.

   It then pins the head as its own account's anchor, with no trust on
   first use. It fetches the chain down to version 1 only to learn the list
   identity, and refuses a chain that does not end in that head.

### Removing a device

`DELETE /devices/{id}` takes a `device_list` body: change 3 without that
device, signed by the caller. The server inserts it inside `revokeDeviceTx`
(`identity_store.go`), in the transaction that revokes the device and queues
its MLS removals. Peers learn of it at their next refresh. From then on, that
device's leaves are `removed` for them and hold sends until the removal
commit lands.

Some revocations have no device signature. Recovery completion is covered
below. Any other server-side revocation leaves a listed device revoked on
the server. **Repair:** any listed device that sees `device.revoked` for a
listed sibling signs change 3 without it, and sends it to
`POST /account/device-list`. The server takes such a removal without recent
auth only when every removed device is already revoked on the server.

### Setting or replacing the recovery key

`PUT /account/recovery-key` (K0-R) takes a `device_list` field: change 5
setting `rk_list_pub′`. The device derives it from the RK it just generated
and the user typed back. The server swaps `{rk_auth_pub, rk_id}` and inserts
the version in one transaction, so an RK the server accepts is always the
RK on the list.

A claim against an account whose head has no recovery key (only a pre-L1
RK not yet confirmed; see [Existing accounts](#existing-accounts)) is
refused with the same 401 as no RK at all, so there is no new oracle.

**This changes how D79 behaves.** Such a claim is **not** counted toward the
D79 cap and does not trigger the leak warning: the user's own correct RK
must not use up their daily cap or warn their devices that the password
leaked. The claim handler still reads and writes the `recovery_attempts`
row on that path, adding 0, so the work and timing stay equal on every
path, decoys included. A wrong RK on such an account counts as D79 says.
The owner and the reviewer should confirm this.

### Recovery when every device is lost (K0-R)

The recovered device must sign the version that names it with `rk_list`. It
must chain from the head **at completion**, not at claim: the head may move
during the 7-day wait. And it must land **before** K0-R's forced RK
replacement, which changes the list's recovery key.

1. **Claim** (K0-R client step 3). After `createEnrollmentCredential`, Rust
   derives the `rk_list` seed from the typed entropy and keeps it in the new
   identity's sealed device record, inside the frozen pending state (schema
   17 storage). The seed never crosses the FFI. RK itself is wiped as today.
2. **Completion** (K0-R step 5). After the session is saved:
   - the device fetches its account's chain from version 1 and verifies it;
   - it checks that the head's recovery key equals the held `rk_list_pub`;
   - Rust signs change 4 listing only this device, and drops the held seed;
   - the device posts it to `POST /account/device-list`.

   The server accepts change 4 only from the device that recovery
   completion enrolled, only while it is the account's one active device,
   and only signed by the head's recovery key. No other device can sign
   then, since completion revoked them all, so there is no race.
3. **Forced changes.** K0-R's forced RK replacement follows as change 5,
   signed by the recovered device.
4. **If the key is not held** (a lost or unreadable pending state, or a head
   whose recovery key differs), the app asks the user to type the RK again,
   and Rust signs from the entropy directly. Until a recovery version lands,
   peers do not add the device; it stays like K0-R's no-peer read-only
   state.
5. **Cancel or expiry** of the claim deletes the pending enrollment and the
   held seed with it.

Peers see a change-4 version and show "<name> recovered their account on a
new device". The safety numbers change as for any new device.

**This is new relative to K0.** K0 keeps nothing derived from RK on a
device. Here a seed that can sign exactly one thing, a device list for this
account, stays sealed on the waiting device for up to 10 days (7-day wait
plus 3 days to claim). A thief who steals that phone and also controls the
server could use it once. Owner question 1 offers the alternative: type RK
again at the end. Either way this needs the independent review.

### Existing accounts

No release exists, so this only matters for demo and test instances. The
server migration creates the tables and leaves existing accounts with no
list. Until one of their devices runs L1, those accounts are "empty": peers
add none of their devices.

- **Migration genesis.** The first L1 device of the account to run shows
  the user every device the server lists (`GET /devices/me`, which returns
  `signing_key`; `domain/types.go:86`): its name, when it was added and when
  it was last seen. The user unticks any they don't recognise. The device
  signs change 6 listing the ticked devices with their keys, then revokes
  the unticked ones (change 3). The server accepts change 6 only with recent
  auth, only while the account has no list, and only for its non-revoked
  devices with matching keys.
- **Trust.** This is the account's own trust on first use, once: the server
  could slip a ghost into that list, and the user's review is the only
  check. A device with no `signing_key` cannot be listed and must be linked
  again.
- **Other devices of the account** fetch the chain and pin it. If one finds
  itself missing, it says "This device isn't approved. Link it again from
  another device."
- **Recovery keys set before L1.** No device holds the entropy, and the
  server's `rk_auth_pub` cannot be trusted as a list key. So the list starts
  with no recovery key, and recovery stays off for that account (the claim
  rule above) until the user types the RK once:
  - Settings shows "Confirm your recovery key to keep recovery working";
  - the app checks the typed key's `rk_id` against the server's;
  - it then signs change 5 with `rk_list_pub`.

  Without this step, every pre-L1 RK would silently stop working.
- **Existing groups** are audited once with `group_members`: every leaf is
  judged as if it had just arrived.

### Concurrency

Two devices of one account may sign version n+1 at once. The server keeps
one row per `(account, version)`, so the second gets 409, refreshes, applies
its change to the new head if it still makes sense, and re-signs.

## Server

**Migration** (next free at landing):

- `device_list_versions (account_id REFERENCES accounts ON DELETE CASCADE,
  version, list_hash, statement BLOB CHECK(length <= 4096), change,
  signer_device_id NULL, created_at, PRIMARY KEY (account_id, version))`.
- An account's head is its highest version. Deleting the account deletes
  its list.

**Routes:**

| Route | Auth | Does |
|---|---|---|
| `GET /api/v1/accounts/{id}/device-list?after=N` | `withAuth` | Statements after version N, at most 64, with `head_version` and `more`. Readers: the account itself, or an account that shares a conversation with it. Any other request gets the same 404 as an unknown account |
| `POST /api/v1/device-lists/query` | `withAuth` | The same, for up to 100 `{account_id, after}` items, at most 256 statements per answer, `more` per item |
| `POST /api/v1/account/device-list` | `withAuth` | Change 6 (with recent auth), change 3 repair, change 4 recovery, under the rules above |
| Setup, register, both link approvals, device revoke, RK `PUT` | as today | Gain a required `device_list` field, inserted in the route's own transaction |

**Checks on every upload:**

- the size, the parse, the account, `version = head + 1` and `prev_hash`;
- the signature, and the signer rules by change;
- every listed device exists in the account, is not revoked, and has the
  same `signing_key`;
- the exact pair the route's action adds or removes.

A wrong version or `prev_hash` answers 409 `device_list_conflict` with
the head version; anything else answers 400 `invalid_device_list`. Nothing
is logged but the account, the version and the change.

**Sync event** `device_list.updated {version}` goes to the account's own
devices, which refresh and re-check their own groups. Peers are not sent
events; they refresh before every decision. That avoids fan-out across
large communities.

**Honest-server gates.** These are defence in depth; clients do not rely on
them.

- Pending changes list adds only for devices on the account's head, so a
  recovered or migrated device is not offered before its version lands.
- Key-package claims and commit bundles name only listed devices.
- A published key package must carry the device's `signing_key` as its leaf
  signature key. This closes bug-hunt Q-1 for an honest server.

## ABI, schema and migration by step

Numbers are the next free ones when each step lands. Today's floors: crypto
ABI 12 with 13 reserved elsewhere, so 14 at the earliest; server migration
0046 with 0047 reserved, so 0048 at the earliest; local schema 18 with 19
possibly taken by K2. Nothing here reserves a number.

| Step | What | Counters |
|---|---|---|
| **L1-1 Rust/ABI** (Opus review and the independent crypto review) | VDL1 parse and `device_list_check_step`; the L1 label in the credential-key sign allowlist (built here if C7 has not), with the VDL1 parse for that label; `rk_list_pub` added to the recovery derive output; hold the recovery seed in the device record, sign change 4 from the hold, or from typed entropy; `expected_signing_key` on adds (change-list version 2); refusal of a changed leaf signing key in `inspect_commit` (shared with C7); commit processing and merge that also return added pairs and the committer pair (one variant with C7's `{removed_any, added_any, new_epoch, root}`); `group_members` returning every leaf's pair (C7's per-member read is a subset). Vectors `testing/vectors/l1-device-list-v1.json`, checked by Rust, Go and Dart: every change kind, every rule violation, non-canonical encodings, Ed25519 edge cases | **One ABI bump.** The device record gains an optional held seed; older libraries refuse such a state (fail closed) |
| **L1-2 Server** (Opus review) | Migration, Go parse and check, the routes, the new fields on existing routes in their transactions, repair, recovery change 4, the claim rule for a head with no recovery key, the honest-server gates, the event, `docs/operations.md` | **One server migration** |
| **L1-3 Mobile** | Pins and keys tables; fetch and verify; the add gate and complete adds; judging commits and Welcomes; the approval hold; message verdicts; the own-account audit; genesis at setup and register; signing at link approval (v2, v3) and on the new device's anchor; revoke; repair; RK set and replace; the recovery hold, the change-4 post and the retype fallback; migration genesis with review; RK confirmation for pre-L1 keys; the one-time group audit; states and strings | **One local schema bump.** No backup plaintext change |
| **L1-4 Own-device alert** (optional; owner question 5) | Hidden W7 type `device_list_alert {account_id, head_version, list_id}`. A device sends it in a group where it found an unapproved leaf of its own account. Receivers refresh that account; a different list identity or a fork becomes `conflict` | No ABI, schema or migration; a W7 type registry entry |
| **L1-5 Review and demo** | Independent review of L1-1 to L1-4. Demo e2e: register, link, message, revoke, recover. A test-only server hook inserts a device row and key package without a list version, and the run shows peers never add it | — |

Each step adds its `docs/crypto.md` change-log entry. With L1-3, the
"What L1 must provide" section points here.

## Threats

| Adversary | Before L1 | With L1 | Left |
|---|---|---|---|
| Server inserts a device and key package for a real account | Peers add it; it reads new messages | Not on any signed version, so L1 clients never stage it. Brought in by a commit, it is held and its messages hidden | — |
| Server re-adds a removed device | Possible | No-return rule. A peer that refreshed refuses it | A peer whose pin is stale and whose refresh the server withholds: caught by the own-account audit if a real device shares the group; L2 |
| Server shows a made-up chain at first contact | n/a | Trust on first use accepts it | Own-account audit; safety numbers; L1-4 alert; L2 |
| Server withholds new versions | n/a | Peers keep the old pin: new devices wait (availability), removed devices stay approved for them | As above |
| Server forks a pinned chain | n/a | Impossible without a listed key | — |
| Stolen unlocked device | Can approve links with recent auth | Can sign versions as a listed device | Until another device removes it. With a malicious server, it can fork against stale peers; seen as a conflict once both branches meet |
| Password and RK stolen, honest server | Recovery after the wait | Same, and the recovery version is signed with RK | Old devices and peers see "recovered" |
| RK stolen, malicious server | Server can add devices anyway | Can sign change 4 with no wait | Peers and old devices see "recovered"; L2 |
| Waiting recovery phone stolen (held seed) | n/a | One change 4, and only if the server completes the recovery | Owner question 1 |
| Member with an honest server hides an Add | Ghost gets nothing without a server roster | Same, and receivers hold it | — |
| Leaf swaps its signing key by update | Allowed today | Refused (the prerequisite) | — |

## What it does not give

- **Key transparency.** First contact, withholding and equivocation toward
  peers that never saw the real chain stay open; L2.
- **Protection from an approved device.** A stolen device signs like the
  real one until it is removed.
- **Hiding device counts and change times from peers.** Peers already see
  leaves in shared groups; the list adds the history of changes.
- **Stable per-account safety numbers.** Group safety numbers still change
  with every device (owner question 4).

## Other packages

- **K2.** A newly linked device anchors its own account through the
  approval (above). It starts with no pins for peers. The K2 bundle should
  later carry the old device's pins, inside the SAS-bound hand-off, so the
  new device does not fall back to trust on first use. That is a container
  plaintext version for K2 to take, not part of L1.
- **K1.** Backups could carry pins the same way (only RK holders make
  backups). That is K1's to decide.
- **C7 (D85).** Newcomers trust the server's device list for departed
  senders' keys. With L1 they can accept a key that some verified version of
  that account's chain listed. That retires D85's trust in the server.
- **D68.** The approval hold and `group_members` close its stated residual
  for devices removed from a list.
- **MLS self-update.** Its trust-model note ("L1 is the real check") is met
  by the entry check plus the signing-key prerequisite.
- **Bug hunt.** TASK-006 closes with L1-3. Q-1 (credential bound to the
  enrollment key) is closed for an honest server by the key-package gate.
- **C4.** Who may change membership stays a role question for C4.

## Open questions for the owner

1. **Recovery signing.** At recovery the new device must sign with a key
   from the recovery key. Keep that key sealed on the waiting phone for up
   to 10 days and use it once at the end (default; one less step for the
   user)? Or ask the user to type the recovery key again when the wait ends
   (nothing extra stored)?
2. **An unapproved device in a chat.** Default: keep syncing, stop sending
   in that chat, hide that device's messages, and show a warning. The
   alternatives are to refuse the change, which stops sync for every chat
   on that phone, or to only warn.
3. **Existing accounts.** Default: on first run, the app lists the
   account's current devices for the user to review, and they become the
   approved list. The alternative is to make the user link every other
   device again. In both cases a recovery key made before L1 must be typed
   once more to keep working; there is no safe way around that. Until then,
   a recovery with that key is refused without counting toward the D79 cap
   (a change to how D79 behaves).
4. **Safety numbers.** Keep today's per-chat numbers, which change whenever
   a contact adds a device (default)? A later package could add a per-
   account code from the list identity, so a verified contact stays verified
   across devices they approve themselves.
5. **Own-device alert (L1-4).** Build it with L1, or leave it to L2 key
   transparency?
6. **No reset.** If someone loses every device and has no recovery key,
   their account can never approve a device again and they need a new
   account. This matches K0. Confirm, or allow an admin reset that every
   contact sees as a new identity, with a loud warning.

## Done when

- **The trust anchor.** Every add on every client is gated by a verified
  list, with the expected signing key enforced in Rust. A test server that
  inserts a device row and key package without a list version never gets
  it added by an L1 client (Go, Dart and demo e2e).
- **The receive side.** A commit or Welcome that brings an unapproved,
  removed or undecided leaf holds the conversation: nothing is encrypted to
  it, its messages are hidden or marked, and sync goes on elsewhere. A later
  removal clears the hold from local evidence only.
- **The prerequisite.** A leaf signing-key change by update is refused.
- **Every flow.** Setup, register, link v2 and v3, revoke, repair, RK set
  and replace, recovery (held seed and retype), migration genesis and
  pre-L1 RK confirmation each produce a version the server and peers accept,
  in the same transaction as the change.
- **Pins.** Lower versions, gaps and broken rules are refused; a fork is a
  sticky conflict with proof.
- **Vectors.** Rust, Go and Dart agree on `testing/vectors/l1-device-list-v1.json`.
- **Review and docs.** Independent review of every step is done, and the
  crypto.md change-log entries are in.
