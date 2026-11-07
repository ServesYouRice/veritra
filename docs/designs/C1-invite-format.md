# C1: invitation links and join requests

Status 2026-11-07. Built on the owner's approval of the format (secret after
the `#`, requests an admin approves). Server migration 0048. Read with
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
follows the existing staged MLS commits (card I51). Binding an invitation to
the target's device keys is not done here and needs its own reviewed design.

## Rules

- Who: an owner or admin of the target creates and revokes invitations, lists
  them, lists pending requests and decides them. Targets are groups
  (conversations of kind `group`) and whole communities. Direct messages and
  community channels take none.
- An invitation has an expiry (default 7 days, at most 90) and a use limit
  (default 1 from the API, 10 from the app, at most 1000). A use is counted
  when a request is approved, not when it is filed.
- It stops working when revoked, expired, used up, when its creator is
  deleted, or when its creator is no longer owner or admin of the target.
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
