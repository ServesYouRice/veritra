# C1: invitation links and join requests

Status 2026-11-07. Built on the owner's approval of the format (secret after
the `#`, requests an admin approves; bound to the target, account and device
keys by D90, see "Binding" below). Server migrations 0048 and 0066 (v2).
Format v2 (owner decision 2026-11-07: close the collusion residual with a
real device signature). **Format v3 since 2026-11-21** (owner approval: the
community-to-shared-group anchor): v2 plus the MLS group the invitation
admits to, signed; see the last section. Read with
[C1-membership-plan](C1-membership-plan.md) and
[C1-progress](C1-progress.md).

## The link

```
<server origin>/join#v3.<secret>.<key commitment>
```

(v3 since 2026-11-21: the same parts as v2, which this section describes;
the signed fields gained the MLS group the invitation admits to. See the last
section. v2 links, like v1, are no longer read.)

`secret` is 32 random bytes, base64url without padding (43 characters). It is
made on the creating device and exists only in the link. `key commitment` is
the first 16 bytes of
`SHA-256("veritra/membership-invite/v2/key-commit\0" || inviter_signing_key)`,
base64url without padding (22 characters): a commitment to the inviting
device's key that the server never needs to see (see "Binding"). A fragment is
never sent in an HTTP request, and the app never puts it in a path, query,
body, log line or error text. `MembershipInviteLink.tryParse` accepts a link
only for the server the user is signed in to, with path exactly `/join`, no
query, no credentials and a canonical secret and commitment; it returns null
otherwise and never echoes the input.

**v1 links are not read.** v1 (`#v1.<secret>`, secret-keyed MAC only) has no
key commitment and no signature, and nothing was released with it (the release
gate is closed and C1 had not merged to a release), so there is no
compatibility to keep: a v1 link is "invalid", a v1 invitation row (made
before migration 0066) is refused by the joiner as "no longer works" and
expires like any invitation. Nothing rewrites those rows.

## What the server sees

The app derives a **locator** from the secret and sends only that, in a
request body:

```
locator = hex(SHA-256("veritra/membership-invite/v1/locator\0" || secret))
stored  = hex(SHA-256("veritra/membership-invite/v1/stored-locator\0" || locator))
```

The server stores `stored` (`membership_invites.locator_hash`). It cannot
rebuild the link or the secret, and a copy of the database does not hold a
usable locator. A locator is a bearer credential for *asking*, not for
joining: it only finds the invitation. Both sides pin the same test vector
(`mobile/test/membership_invite_link_test.dart`,
`TestHashLocatorVector`).

Limit, stated plainly: the locator authenticates nothing end to end. A
malicious server could file requests for accounts that send it a locator, but
every request still waits for an admin, and joining changes only the
server's membership record. Membership never means encrypted access: that
follows the existing staged MLS commits (card I51). What ties the link to its
target is the binding below.

## Binding to the target, account and device keys (D90, v2)

Status 2026-11-07. Decision D90: the invitation is bound to the inviter's
target, account and device keys before merge. v1 did it with a MAC keyed by
the link secret, which anyone holding the link can compute, so a server that
colluded with a link holder could swap the target. v2 (owner decision
2026-11-07) adds what v1 lacked: a signature by the inviting device and an
anchor for the key it is checked against. v2 keeps v1's tag and adds the two.

```
binding_key = SHA-256("veritra/membership-invite/v1/binding-key\0" || secret)
fields      = lp(origin) || lp(target_kind) || lp(target_id)
              || lp(inviter_account_id) || lp(inviter_device_id)
              || lp(inviter_signing_key)
tag         = hex(HMAC-SHA256(binding_key, "veritra/membership-invite/v1/binding\0" || fields))
message     = fields || lp(locator)              (locator as its 64 ASCII hex characters)
signature   = Ed25519(inviter credential key, "veritra-invite-binding-v2" || message)
commitment  = SHA-256("veritra/membership-invite/v2/key-commit\0" || inviter_signing_key)[0..16]
```

`lp(x)` is a 16-bit big-endian length and the bytes, so adjacent fields
cannot trade characters. `origin` is the canonical server origin of the link.
`target_kind` is `group` or `community`. `inviter_signing_key` is the 32-byte
Ed25519 public key of the inviting device's MLS credential, the same key the
server holds as `devices.signing_key`. The key labels differ from the locator
label, so the locator the server sees is no key and gives no tag. The signed
message ends with the link's own locator, so a signature the inviter made for
one link is no answer for another link of the same inviter (a server that
holds a genuine signed binding for link B cannot present it for link A).

**The signing domain.** `veritra-invite-binding-v2` is a new entry in the ABI
13 sign and verify allowlist (`crypto/rust/src/c7.rs`, `SIGN_DOMAINS`), next
to the two C7 domains. Rust prepends the label itself, so no one can ask the
engine to sign chosen bytes under another protocol's label, and a signature of
one domain never verifies in another (a test pins that no label is a prefix of
another). It is an allowlist entry only: no function, length, struct or ABI
layout changed (the integration pins ABI 21), and a library without the entry refuses
the domain, so the app fails closed. The Dart side adds bindings for the
already exported `pm_crypto_c7_sign` and `pm_crypto_group_member_signature_key`
behind a new capability interface (`InviteBindingCryptoService`) that only the
native engine implements; `UnavailableCryptoService` is untouched.

Vectors: `testing/vectors/invite-binding-v2.json` (a fixed secret and signing
seed, the locator, the commitment, the signed message, the signature and the
link fragment). Ed25519 is deterministic, so Rust
(`crypto/rust/src/invite_binding_tests.rs`, from the written layout), Go
(`TestInviteBindingV2Vector`, standard-library `crypto/ed25519`, no new
dependency) and Dart (`membership_invite_link_test.dart`, the message and
commitment; `invite_binding_native_test.dart`, the signature through the
engine) all reproduce or verify the same bytes. The v1 MAC vectors stay
(`TestInviteBindingTagVector`, the RFC 4231 cases).

**Creating.** The app reads its own device's signing key from the native
engine (`pm_crypto_device_signing_public_key`; builds without the engine,
including `UnavailableCryptoService`, make no invitation), generates the
secret, builds the link with the key commitment, signs `message` with the
device (`pm_crypto_c7_sign`), checks its own signature with the strict
verifier, and sends `locator`, `signing_key`, `binding_tag` and
`binding_signature` (base64, 64 bytes) in the body. The device and account are
the session's, never fields of the request. The server stores the creating
device's id and the key it holds on record for it, and refuses (400
`invalid_input`) a body whose key differs from that record, a session with no
device, a tag that is not 64 lowercase hex characters, and a signature that is
not 64 bytes. It cannot check the tag (that needs the secret) or the signature
(it does not know the origin the link names): it stores them for the joiner. An
invitation is bound to its device, so it stops working when that device is
revoked. Migration 0066 adds `membership_invites.binding_signature` (nullable
BLOB, 64 bytes when set); `binding_tag` and every other column are unchanged.

**Joining.** `POST /membership-invites/preview` returns `binding` (target
kind and id, inviter account id, inviter device id, inviter signing key, tag
and `signature`) and `POST /membership-invites/requests` returns it again on
the answer. Before it shows the target, and again before it keeps a request,
the app checks all of this and **fails closed** on any miss
(`AppState._inviteBindingHolds`):

1. The kind it shows equals the bound kind; the key is 32 bytes and its
   commitment equals the one in the link; the signature is 64 bytes; the tag
   is the one the secret makes (`MembershipInviteLink.matches`).
2. The signature verifies, strictly, under that key over the message the link
   rebuilds, in the invitation domain (`pm_crypto_c7_verify`). A build without
   the engine accepts nothing.
3. The roster. For every conversation this device holds an MLS group for, it
   reads the signature key of the inviting device (account and device id from
   the binding) from the group's current tree
   (`pm_crypto_group_member_signature_key`). A group that has no such member
   says nothing; a group that names a key other than the binding's refuses the
   link.

- On preview: a miss shows the ordinary "this link no longer works" message and
  files nothing.
- On request: the answer must carry the binding of this very link and pass the
  same checks. Otherwise the app withdraws the request (best effort) and shows
  the same message, so a server cannot show the genuine target at preview and
  file against another.

What this proves: whoever made the link named exactly this target, inviting
account and device, signed it with the key the link commits to, and neither the
server nor a second holder of the link changed any of them. This closes the
collusion case v1 left open. A server that colludes with someone who holds the
link knows the secret, so it can recompute the MAC, but it cannot sign with the
inviter's key, and it cannot name another key that fits the commitment in the
joiner's copy of the link.

The anchor is the commitment, not the roster, and that is a deliberate
departure from "verify against the MLS roster": a person joining through an
invitation is, by definition, not in the target group, and often shares no group
with the inviter, so the target group's roster does not exist on their device.
Requiring a roster hit would refuse nearly every invitation. The roster is used
where it exists (it also anchors a link that reached the joiner through a path
the server could rewrite, for an inviter the joiner already knows through a
shared group), and the commitment carries every other case. **Open owner
question:** whether to also refuse an invitation from a stranger (no shared
group) outright; the owner's brief said "fail closed" and this build reads it as
"refuse on any failed or missing check", not "refuse when no roster exists".

Limits, stated plainly:

- **The link must reach the joiner out of the server's sight.** The
  commitment lives in the fragment. A server never receives the fragment from
  the app, but if the link passed through the server (a link posted in a public
  community, a main use case given a use limit of up to 1000, or sent in a
  message the server relays and could rewrite, though messages are end-to-end
  encrypted), the server can read it, can swap in its own key, recompute the
  commitment, the tag and a signature under that key, and the joiner cannot
  tell. The only anchor that survives that is the roster, and only for an
  inviter the joiner already shares a group with. Joining a community through a
  link the server can read is trust in the server, and the app must not
  describe it as verified.
- **The roster read covers local groups only.** It does not ask the server and
  it skips a conversation whose group cannot be read (no group on this device,
  a poisoned handle, leaves of one identity with different keys). A server
  cannot hide a shared group from it by editing a cache: it tries every local
  conversation.
- **Shared-group conversations.** Community channels may share one MLS group
  (C0). The scan uses each conversation's own id as the group id, as the rest
  of the app does for a plain group, so a channel whose group has another id
  is read as "no group". This can only weaken the extra roster check, never
  make a check pass that failed.
- **Names are not bound.** The target name and the inviter's username are
  server-supplied text shown for orientation; the bound target is the id.
  Encrypted names wait for W11 and C3.
- **Existing devices.** A device registered without a signing key (before
  enrollment proofs) cannot create an invitation.
- **Needs independent review.** This is a security decision; D90 and AGENTS.md
  ask for one before the invitation format is final. Not done here (no review
  agent was available in this run): the ABI 13 domain addition, the message
  layout and the commitment choice need the review.

## Rules

- Who: an owner or admin of the target creates and revokes invitations, lists
  them, lists pending requests and decides them. Targets are groups
  (conversations of kind `group`) and whole communities. Direct messages and
  community channels take none.
- An invitation has an expiry (default 7 days, at most 90) and a use limit
  (default 1 from the API, 10 from the app, at most 1000). A use is counted
  when a request is approved, not when it is filed.
- It stops working when revoked, expired, used up, when its creator is
  deleted, when the device that made it is revoked, or when its creator is no
  longer owner or admin of the target.
  Every unusable or unknown locator answers 404, so links cannot be probed.
  A block between requester and creator also answers 404.
- A request grants nothing: no membership, envelope, attachment, key package
  or roster. One pending request per account and target; asking again returns
  it. At most 20 pending per account and 200 per target; at most 50 active
  invitations per target.
- Approval is one transaction: the request moves `pending` to `approved`
  (guarded, so concurrent approvals change it once), the use is counted, and
  the requester joins as `member` through the same code as adding by hand
  (blocks, member and conversation limits, rank rules, sync events). A
  refusal rolls everything back and leaves the request pending. Repeating
  the same decision succeeds without effect; the opposite one is 409.
- Revoking an invitation cancels its pending requests. A pending request
  whose invitation died is not listed and is replaced when the account asks
  through a new link.
- A community approval joins every channel conversation, as adding a member
  does today. C0 shared-group routing is not built, so this is still one
  MLS group per channel.

## Leave and remove (communities)

`DELETE /communities/{id}/members/{account|me}`: one transaction removes the
community membership, every channel membership of the account and its
receipts, and writes the same `membership.removed` or `membership.left`
events per channel as group removal (for remaining members, and for the
removed account). The last owner cannot leave; removing needs a manager of
strictly higher rank. Groups keep their existing routes.

## Not built

- Rename is built through encrypted metadata, not a rename route: the group
  profile editor (W11) and the community and channel info editor (C3). No
  plaintext rename route was added (2026-11-21).
- Join-request notifications: admins read the list when they open it.
- C0 shared groups, per-conversation sync bounds, client cursors.

## 2026-11-09 port: group Welcome anchor (partial C1)

The port uses crypto ABI 21, local schema 32 and server migration 0066.
Before submitting a group join request, the app fetches and verifies its
binding again and persists the target group id, inviter account/device and
committed signing key in `local_invite_anchors`. This table holds no secret
or locator, is excluded from backup/history exports, and is cleared on
identity replacement, backup restoration and full wipe. The key remains
pinned after joining; a later explicit request through a verified link may
replace it.

After `joinGroup` checks the Welcome's actual MLS group id against the target
conversation id, the receiver reads the inviter leaf key and compares it
with that anchor before sealing or committing any state. A missing inviter
or a different key restores the previous state and enters the existing
per-conversation failure/retry UI. No cursor or processed marker is written.
This refuses the join rather than trusting a server roster.

This is a group-only D99 slice. Community target ids differ from shared MLS
group ids: the signed invitation does not carry that shared id. A durable
community anchor and authenticated mapping still need implementation and
review. C1 remains open (encrypted rename is wired through W11 and C3).
The owner requested solo work, so no independent review was performed.

## 2026-11-21: v3, the shared-group anchor (community and group)

Owner approval 2026-11-21 ("community-to-shared-group invite anchor"). A
community's id is not the id of the MLS group a joiner is welcomed into (the
C0 shared conversation), and v2 did not sign that group, so a joiner of a
community could not tell which group the invitation was anchored to: a server
could name any group as the community's and the Welcome check above had no
anchor to apply. v3 signs it. No crypto ABI, Rust, server migration or local
schema change.

**What is signed.** Every field of v2, plus `anchor_group_id`, and a version
field first:

```
fields    = lp("veritra/membership-invite/v3") || lp(origin) || lp(target_kind)
            || lp(target_id) || lp(anchor_group_id) || lp(inviter_account_id)
            || lp(inviter_device_id) || lp(inviter_signing_key)
tag       = hex(HMAC-SHA256(binding_key, "veritra/membership-invite/v3/binding\0" || fields))
message   = fields || lp(locator)
signature = Ed25519(inviter credential key, "veritra-invite-binding-v2" || message)
```

`anchor_group_id` is the MLS group id (the conversation id) the joiner will
be welcomed into: the group's own id for a group, and the community's C0
shared conversation for a community. It is never empty. `binding_key`, the
locator and the key commitment are v2's, unchanged. The signing domain stays
`veritra-invite-binding-v2` (the ABI allowlist entry, so no Rust change); the
version lives in the message instead. A v2 message starts with `lp(origin)`
and an origin always has a scheme, so no v2 message equals a v3 message and
a signature made for one layout never verifies as the other. Vector:
`testing/vectors/invite-binding-v3.json` (Go builds it with the standard
library; Dart checks the message, the tag and the fragment, and the native
engine verifies the signature).

**The link.** `<origin>/join#v3.<secret>.<key commitment>`, the same parts as
v2. The anchor is not in the link: the joiner reads it from the server and
the signature authenticates it, which keeps the link short.

**Downgrade.** The version is in the fragment, which the server never sees,
and is chosen by the inviting app. The app reads only `v3.` links; v1 and v2
links are "invalid" and v2 invitations made before this change "no longer
work" and expire (nothing was released with either, the same rule v2 applied
to v1). A v3 joiner rebuilds only the v3 message, so a server that strips or
swaps the anchor, or returns a v2-era signature, fails the signature. The
joiner also refuses an empty anchor, and a group whose anchor is not its own
id.

**Creating.** The app takes the anchor from what it holds: the group id, or
the community's `shared_conversation_id`. A legacy community (no shared
group, only while the server's `PRIVATE_MESSENGER_COMMUNITY_LAYOUT` switch is
off) gets no invitation from the app. Before signing, the app reads its own
leaf in that MLS group (`pm_crypto_group_member_signature_key`) and refuses
unless it is this device with its own key: it anchors only a group it is in.
The body carries `anchor_group_id`; the server derives the same value (the
group id, or `community_layouts.shared_conversation_id` of an active layout)
and answers 400 `invalid_input` to a mismatch. It stores nothing new and
returns the derived value as `binding.anchor_group_id` on the preview and on
the request answer. If a community's shared group ever changed, its earlier
invitations would stop verifying: fail closed. (A legacy community derives
no anchor; the server still accepts an anchor-less body for it, which no v3
app makes and no v3 joiner accepts.)

**How the joiner verifies.** On preview and again on the request answer,
before showing the target or keeping a request:

1. v2's checks over the v3 fields: shown kind, key commitment, tag, the
   signature in the invitation domain, and the roster check.
2. `anchor_group_id` is not empty; for a group it equals `target_id`.
3. Community: if this device already pinned the community to a group (an
   earlier verified link), the new anchor must be the same group.
4. The request answer must carry the same target and anchor as the preview.

Before filing the request the app pins, for both kinds,
`InviteAnchor(anchor_group_id, inviter account, device, key)` (the D99 table,
schema 32), and for a community also `community -> anchor_group_id` (an
encrypted local setting `c1.community_anchor.<id>`, cleared with the invite
anchors on identity replacement, backup restore and wipe, never exported).
Then:

- **Welcome.** The D99 check now covers communities: a Welcome to the anchor
  group is committed only if the group's actual MLS id is that id and the
  inviter's leaf in it carries the pinned key; otherwise the state is
  restored and the conversation enters the per-conversation failure UI.
- **Mapping.** When the app lists communities, a community it pinned is
  shown only if the server's `shared_conversation_id` is the pinned group
  and every open or announcement channel is routed to it. A server that
  names another group (a replay of the invitation into another group) gets
  the community hidden, not shown with that group. Hidden is not "left":
  nothing that cleans up after a left community runs for it (C3 rotation
  marks stay), and a pin the store cannot read keeps the list already shown.

**What the server learns.** Nothing new: it already holds the community's
shared conversation, and the anchor in the create body is that value. The
preview now shows that opaque id to a signed-in link holder who is not yet a
member; it opens nothing without membership (every route checks it).

**Limits, stated plainly.**

- The inviting app's own idea of which group is the community's comes from
  the server's listing plus its MLS membership of that group. A server that
  lies to the inviter can make it anchor another group the inviter is in;
  the joiner then joins that real group of the inviter's. Closing this needs
  an end-to-end signed community-to-group record (the C0 layout control
  record of `C0-preserving-migration.md`), not built.
- A pin exists only for a join through a link. A member added by hand, or a
  device that joined before v3, trusts the server's mapping as before.
- The link must still reach the joiner out of the server's sight (see the v2
  limits); a link the server can read gets no protection.
- A group the server substitutes can still appear as a row in the chat
  list (its conversation is listed by the server); it is never shown as the
  pinned community.
- Trust on first verified link: the pin is written from a verified preview
  before the request is filed and stays even if the server then answers
  `already_member` or 404; a later link for the same community must name the
  same group until a wipe or identity change. A server gains nothing new
  from this (it already controls the listing).
- The Welcome anchor names the inviter's leaf (D99). If the inviter leaves
  the shared group before the joiner's Welcome, the Welcome is refused until
  a new verified link replaces the anchor; likelier in a large community.
- Private channels have their own groups and are not anchored (a joiner is
  not added to them on approval).
- **Needs the independent security review**, with the rest of v2.
