# C1: invitation links and join requests

Status 2026-11-07. Built on the owner's approval of the format (secret after
the `#`, requests an admin approves; bound to the target, account and device
keys by D90, see "Binding" below). Server migration 0048. Read with
[C1-membership-plan](C1-membership-plan.md) and
[C1-progress](C1-progress.md).

## The link

```
<server origin>/join#v1.<secret>
```

`secret` is 32 random bytes, base64url without padding (43 characters). It is
made on the creating device and exists only in the link. A fragment is never
sent in an HTTP request, and the app never puts it in a path, query, body,
log line or error text. `MembershipInviteLink.tryParse` accepts a link only
for the server the user is signed in to, with path exactly `/join`, no query,
no credentials and a canonical secret; it returns null otherwise and never
echoes the input.

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

## Binding to the target, account and device keys (D90)

Status 2026-11-07. Decision D90: the invitation is bound to the inviter's
target, account and device keys before merge. The joiner checks the binding
from the link secret, so a server that never saw the secret cannot swap the
target, the inviting account or the inviting device's key without the check
failing.

```
binding_key = SHA-256("veritra/membership-invite/v1/binding-key\0" || secret)
message     = "veritra/membership-invite/v1/binding\0"
              || lp(origin) || lp(target_kind) || lp(target_id)
              || lp(inviter_account_id) || lp(inviter_device_id)
              || lp(inviter_signing_key)
tag         = hex(HMAC-SHA256(binding_key, message))
```

`lp(x)` is a 16-bit big-endian length and the bytes, so adjacent fields
cannot trade characters. `origin` is the canonical server origin of the link.
`target_kind` is `group` or `community`. `inviter_signing_key` is the 32-byte
Ed25519 public key of the inviting device's MLS credential, the same key the
server holds as `devices.signing_key`. The key label differs from the locator
label, so the locator the server sees is no key and gives no tag. Both sides
pin one vector: `mobile/test/membership_invite_link_test.dart` and
`TestInviteBindingTagVector` (HMAC-SHA256 cases from RFC 4231 are pinned on the
Dart side, where the HMAC is written on the existing SHA-256).

**Creating.** The app reads its own device's signing key from the native
engine (the existing `pm_crypto_device_signing_public_key`, behind a small
Dart interface; builds without the engine, including
`UnavailableCryptoService`, make no invitation), generates the secret, and
sends `locator`, `signing_key` and `binding_tag` in the body. The device and
account are the session's, never fields of the request. The server stores the
creating device's id and the key it holds on record for it, and refuses (400
`invalid_input`) a body whose key differs from that record, a session with no
device, and a tag that is not 64 lowercase hex characters. It cannot check the
tag: that needs the secret. An invitation is bound to its device, so it stops
working when that device is revoked.

**Joining.** `POST /membership-invites/preview` returns `binding` (target
kind and id, inviter account id, inviter device id, inviter signing key, tag)
and `POST /membership-invites/requests` returns it again on the answer. The
app recomputes the tag from the link and compares in constant time, and
checks that the kind it shows equals the bound kind.

- On preview: a mismatch, a missing binding or a key of the wrong length
  shows the ordinary "this link no longer works" message and files nothing.
- On request: the answer must carry the binding of this very link. Otherwise
  the app withdraws the request (best effort) and shows the same message, so a
  server cannot show the genuine target at preview and file against another.

What this proves, against a server that never saw the link: whoever made the
link named exactly this target, inviting account, device and device key, and
the server did not change any of them. It proves nothing against a server that
holds the link (see the limits below). It adds no round trip and no new key
material, and needs no change to the crypto ABI.

Limits, stated plainly:

- **No signature.** The tag is a MAC keyed by the link secret, not a
  signature by the device. Anyone holding the link can compute tags. So a
  server that holds the link (it colludes with a recipient, or it is the
  recipient) can swap the target, the inviting account or the device key and
  recompute a valid tag, and the joiner cannot tell. The binding protects
  only against a server that never saw the secret.
- **The device key comes from the server and is not cross-checked.** The
  joiner learns the inviting device's key from the server, and the tag is
  computed over that key, so the tag does not vouch for it. Checking it
  against the account's signed device list needs L1, and against the MLS
  roster needs C7's member signature-key read. Until then the key is bound to
  the link, not proven to belong to the inviting account.
- **Public links.** Any link the server operator can read gives no protection
  against the server. That includes a link posted in a public community, a
  main use case given a use limit of up to 1000: the server reads the link
  where it is posted, can compute the locator and the tag, and can answer
  with any target or key it likes. The binding is meaningful only for a link
  that reaches the joiner through a channel the server does not see. Joining
  a community through a link the server can read is trust in the server, and
  the app must not describe it as verified.
- **v2 must close both gaps together.** A signature alone does not close the
  collusion case: the joiner still gets the inviter's key from the server, so
  a server holding the link can substitute its own key, sign a swapped target
  with it and recompute the HMAC over that key, since it has the secret.
  v2 is an ABI-13 credential-key signature over the same `lp()` fields, plus
  a key commitment the server cannot replace. Candidates for the commitment:
  a truncated SHA-256 of the inviter key placed in the link fragment (the
  server never sees the fragment, but this only helps when the link itself
  did not pass through the server); an L1 signed-device-list check; or C7's
  roster signature-key read. The signature itself needs a verifier in the
  crypto ABI, which ABI 12 does not have on purpose (TASK-007 removed the raw
  signer; the enrollment-proof signer has its own domain and mints a key
  package). C7's reserved ABI 13 adds credential-key sign and verify over a
  domain allowlist, with a new domain label, and the format version moves to
  `v2`. For a link the server can read (see "Public links") even v2 gives no
  protection against the server, because the server can also rewrite a
  fragment commitment it can see.
- **Names are not bound.** The target name and the inviter's username are
  server-supplied text shown for orientation; the bound target is the id.
  Encrypted names wait for W11 and C3.
- **Existing devices.** A device registered without a signing key (before
  enrollment proofs) cannot create an invitation.
- **Needs independent review.** This is a security decision; D90 and AGENTS.md
  ask for one before the invitation format is final.

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

- Rename: group and community names must be encrypted metadata (W11 and C3),
  neither of which exists. No plaintext rename route was added.
- Join-request notifications: admins read the list when they open it.
- C0 shared groups, per-conversation sync bounds, client cursors.
