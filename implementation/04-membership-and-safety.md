# Plan 04 — Membership, identity, and safety

Server membership is routing authorization. MLS membership is cryptographic
authorization. The UI must never imply that changing one proves the other.

## M01 — Add scoped conversation member listing

Audit references: LOG-07, UI-05.

Objective:
Let authorized members inspect the current server-side conversation roster and
roles.

Read first:

- community member-list implementation as a pattern
- server/internal/storage/community_store.go
- server/internal/httpapi/conversation_handlers.go
- server/internal/domain/types.go
- docs/api.md

Steps:

1. Define a minimal response with account ID, username, role, and server
   membership time; do not expose email, devices, or secrets.
2. Require current conversation membership.
3. Add stable pagination if the existing 100-member cap requires it.
4. Add tests for member, nonmember, blocked account visibility, and deleted
   account handling.
5. Document that this is the server routing roster, not verified MLS state.

Acceptance:

- A member can inspect exactly the roster needed to understand recipients.
- Nonmembers learn nothing about the conversation.
- The response contains no private content or unnecessary profile metadata.

## M02 — Add leave, kick, and role lifecycle

Audit references: LOG-07, UI-05.

Depends on: M01, Y02 transaction pattern.

Objective:
Provide complete server-side membership lifecycle with safe last-owner and
rank rules.

Steps:

1. Specify self-leave, remove/kick, role change, owner transfer, last-owner,
   deleted conversation, and community-channel inheritance semantics.
2. Add store methods that commit membership change plus durable event.
3. Permit self-leave where policy allows; require rank checks for removal.
4. Stop future routing and push immediately after server removal.
5. Retain historical ciphertext policy explicitly.
6. Add race/idempotency tests for simultaneous leave/kick/owner transfer.

Acceptance:

- A user can leave harassment/unwanted groups.
- Moderators cannot remove or promote equal/higher roles.
- No conversation is left without a valid owner unless deletion semantics
  explicitly permit it.
- Every successful change has a durable event.

## M03 — Coordinate server and MLS removal

Audit references: LOG-07, SEC-01.

Depends on: M02, C07.

Objective:
Expose honest pending/complete membership states while authorized clients
create and process MLS add/remove commits.

Steps:

1. Specify the state machine for requested, routing-revoked, commit-pending,
   cryptographically-removed, failed, and expired operations.
2. Bind MLS commit acknowledgements to authenticated group/epoch/member data.
3. Do not restore server routing merely because one crypto commit is delayed.
4. Define recovery when all authorized committers are offline.
5. Add offline, concurrent, stale-epoch, and malicious-acknowledgement tests.

Acceptance:

- UI can distinguish server routing removal from cryptographic removal.
- A malicious client cannot mark another credential removed without an
  authenticated MLS transition.
- Offline members converge without silent roster divergence.

## M04 — Canonicalize DMs and return peer identity

Audit references: UI-03, LOG-12.

Depends on: S02.

Objective:
Reuse one DM per unordered account pair and return the peer identity only to
the two members.

Steps:

1. Specify an unordered pair key or conflict-safe lookup under a transaction.
2. Make create-DM act as get-or-create for the pair.
3. Do not merge existing duplicate histories or MLS groups automatically.
4. Add peer account ID and username to the authorized conversation summary.
5. Define how existing duplicates are displayed and migrated non-destructively.
6. Test concurrent creation, blocking, deleted account, and authorization.

Acceptance:

- Two simultaneous creates yield one canonical new DM.
- Only members receive peer metadata.
- Existing duplicate history is never silently merged or deleted.
- The response is sufficient for U01.

## M05 — Expose block and unblock controls

Audit reference: UI-06.

Objective:
Make the existing account block API reachable from DM details and Settings.

Read first:

- server block semantics and docs/api.md
- mobile conversation details and settings screens
- mobile API client and models

Steps:

1. Add block/unblock to DM details with a confirmation that explains effects.
2. Add a blocked-accounts list with unblock.
3. Refresh affected conversations/events without leaking the block to the
   blocked account.
4. Clarify that blocking suppresses future delivery/routing but does not erase
   ciphertext already held by other devices.
5. Add widget and AppState tests.

Acceptance:

- A user can block, inspect, and unblock without curl.
- Controls are accessible without gesture-only interaction.
- Copy does not promise remote deletion or cryptographic erasure.

## M06 — Decide audit-event metadata minimization

Audit reference: MERGE-04.

Objective:
Document and enforce which social-graph fields are operationally necessary in
owner/admin audit events.

Steps:

1. Inventory every event type and metadata field.
2. Compare each field with docs/threat-model.md and its operational purpose.
3. Prefer actor-local history for block actions; remove or pseudonymize target
   IDs from global admin views if they are not required.
4. Document retention and who can read the events.
5. Add tests that forbid content, ciphertext, secrets, and disallowed fields.

Acceptance:

- The policy admits unavoidable server metadata without claiming it is E2EE.
- Global audit rows contain only justified fields.
- Existing incident/account-management needs remain possible.

## M07 — Design member-safe account recovery

Audit references: NICE-01, NICE-02, corrected Fable L-13.

Depends on: C08, C11.

Objective:
Provide honest authentication/key recovery without admin impersonation or key
escrow.

Steps:

1. Separate password/authentication recovery from message-key recovery.
2. Prefer a user-held recovery secret or verified-device transfer.
3. Define permanent-loss behavior when neither exists.
4. Revoke sessions/device secrets and rotate credentials after recovery.
5. Require MLS group updates before claiming restored trust.
6. Threat-model malicious admin, stolen recovery secret, replay, and rollback.

Acceptance:

- Admins cannot recover plaintext or silently impersonate a member.
- Password reset alone never claims to recover MLS keys/history.
- Every path has explicit user-visible loss and rotation semantics.

## M08 — Add session inventory and renewal later

Audit reference: MERGE-05.

Priority: after production crypto and core safety.

Objective:
Let users inspect/revoke sessions and reduce long-lived bearer-token exposure.

Steps:

1. Decide whether device inventory is sufficient or separate session rows must
   be visible.
2. Add token identifiers and last-used coarse time without storing raw tokens
   or analytics.
3. Implement bounded renewal/rotation and theft replay handling.
4. Revoke on password, device, suspension, and recovery events.
5. Test active WebSocket expiry/rotation.

Acceptance:

- Raw tokens never appear in storage responses or logs.
- Users can revoke unknown access.
- Rotation does not strand offline devices without a defined re-link path.

## M09 — Add peer credential verification

Audit reference: MERGE-09.

Depends on: C07, M04.

Objective:
Let users compare a locally derived peer/conversation credential fingerprint
without trusting a server-authored verification value.

Steps:

1. Define which stable, authenticated user/device credentials the fingerprint
   covers and how device additions/removals change it.
2. Derive a human-comparable SAS/fingerprint entirely on the clients with
   domain separation and a versioned encoding.
3. Add an accessible compare/scan flow that clearly distinguishes verified,
   changed, and unverified state.
4. Store verification state locally in the encrypted database and invalidate
   it on relevant credential changes.
5. Test two-device agreement, server substitution, stale credentials, QR
   tampering, accessibility, and version mismatch.

Acceptance:

- Two honest clients derive the same value without server-selected comparison
  material.
- A substituted or changed credential produces a visible verification change.
- The UI never equates ordinary server authentication with peer verification.
