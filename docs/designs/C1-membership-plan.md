# C1: community and group membership implementation plan

Prepared 2026-10-26 against the current working tree. **Planning only; no
protocol, schema or product decision is approved by this document.** C1 is
still open. D50 orders implementation after L0, W8 and K2. Read this together
with [C0](C0-community-groups.md), [W11](W11-profiles.md) and
[`docs/crypto.md`](../crypto.md). An independent review is required before
the security, sync, membership or migration changes are implemented.

## Confirmed current behavior

| C1 behavior | Existing code | Missing work |
|---|---|---|
| Group member list with usernames | `ListConversationMembers` in `server/internal/storage/community_store.go`; `ConversationMember`, `ApiClient.conversationMembers`, `AppState.loadConversationMembers`; `conversation_details_screen.dart` | Keep this existing flow and extend its tests for the join workflow |
| Group add, remove and leave | Existing conversation `/members` GET/POST/DELETE; `ManageConversationMember`, `RemoveConversationMember`; Flutter details screen and AppState actions | Invite-based requests and approval; preserve last-owner protection and honest pending-MLS wording |
| Group creation | `ApiClient.createConversationDetailed` / `AppState.startConversation` | Encrypted group rename/profile implementation (W11), rather than a plaintext title update |
| Community creation and channel navigation | `CommunityScreen`, create/list community/channel API and storage | Community settings, member list, requests, leave/remove, encrypted rename |
| Community member list and add/change role | `/communities/{id}/members` GET/POST; `ListCommunityMembers`, `ManageCommunityMember` | Community list currently returns account IDs/roles/times without the username join used by groups; Flutter has no wrappers or management UI |
| Community leave/remove | None; `RemoveConversationMember` explicitly permits only `group` | One atomic community removal affecting the correct MLS groups and scoped receipt cleanup/events |
| Invite links for groups/communities | None | Existing `/invites` and `InviteScreen` are instance-account-registration invitations, not membership invitations |
| Approval queue | None | Bounded, expiring, target-scoped requests and explicit administrator approval/rejection |
| MLS membership coordination | `_reconcileMlsMembership`, pending changes API, key-package claiming and staged commits exist | Reuse them; map one membership operation to the C0 shared group plus authorized private groups |

The existing community implementation is **not C0**: every channel has a
`community_channel` conversation and `ManageCommunityMember` joins every
channel. `private` and `announcement` are labels in this path. C1 must not
present them as access isolation or admin-only posting.

## Prerequisites that cannot be skipped

1. **Isolate MLS failures by conversation.** C0 explicitly says open invites
   cannot ship while one bad MLS ciphertext halts the global cursor.
   `_runOwnedCatchUp` still loads one durable `SyncRecovery` and stops the
   entire catch-up; its failure handler stores the same global recovery.
   W7 step 0 handles successfully decrypted but invalid/unsupported payloads;
   it does not solve undecryptable MLS messages. A separately reviewed design
   must retain failed ciphertext and the last good group state without
   advancing that group's ratchet, while other conversations continue.
   It must cover replay/retry, restart, bounded storage and recovery UX.
   Dropping undecryptable messages or silently resetting a group is not an
   acceptable shortcut.
2. **Implement C0 shared-group routing.** A community needs exactly one
   `community_shared` conversation for open/announcement channels and a
   separate group for each private channel. Channel rows need a conversation
   reference. Server envelope validation and client payload validation must
   bind the same `channel_id`; per-channel history/unread projections must
   work over the shared group. Existing demo communities are recreated under
   the reviewed C0 migration policy, never silently reinterpreted as private.
   Recheck W8's finished receiver context support before editing it.
3. **Provide encrypted rename.** Group names use W11's encrypted group
   profile mechanism; community/channel names use the C3 information design
   or an independently reviewed reuse of that record mechanism. Existing
   plaintext `communities.name`, `channels.name` and `conversations.title`
   are legacy paths, not permission to add new plaintext rename endpoints.
   If only membership ships first, label it a C1 substep and leave C1 open.

These are code/design prerequisites, not missing accounts, infrastructure or
dependencies. K2 may provide reusable historical metadata import, but it
does not itself remove any prerequisite above.

## Smallest complete C1 package

After the prerequisites, implement one consistent membership flow for
existing signed-in accounts. Instance registration remains its own flow.

- An allowed administrator creates a group/community invitation with expiry,
  use limit and revocation. Its secret remains in the URL fragment after
  `#`; the app constructs the link locally. Never put the fragment in an
  HTTP path, query, referrer, audit entry, exception or request body.
- A signed-in recipient pastes/scans the link and sees the target and
  inviter context before explicitly requesting to join. A request grants no
  membership, envelope visibility, attachment access or MLS key package.
- Administrators see a bounded request list with usernames and may approve
  or reject. Approval and membership/event writes happen atomically and
  tolerate concurrent/repeated decisions. Exhausted, expired, revoked,
  wrong-target and already-resolved requests fail safely.
- Approval records server membership first and schedules existing staged
  MLS coordination. The UI distinguishes **approved, waiting for encrypted
  access** from a completed MLS Welcome. Membership alone never means that
  cryptographic access has changed.
- Group/community details show usernames and roles only to co-members.
  Reuse existing group add/remove/leave controls and hierarchy. Add community
  controls with last-owner safeguards. Never claim a server roster is proof
  of MLS membership or approved-device integrity (L1 remains separate).
- Leave/removal updates the complete affected set once: the shared group
  and the private groups the target actually belongs to. In one transaction,
  remove server memberships/receipts, persist notifications for remaining
  members and the removed account, and cause normal MLS reconciliation.
  The removed account loses server access immediately; future MLS access
  ends only after the removal commit. Old history already held is retained
  or deleted according to the existing local policy, not erased remotely.
- Rename uses encrypted metadata, validates on reception, updates the local
  list/detail titles, and is distributed only to current authorized members.

The invitation wire format, verifier/proof, secret lifecycle and binding to
the exact target/account/device keys need an independent design review.
Do not equate a server-returned invitation label or a server-side boolean
approval with end-to-end authentication. Reusing the L0 codec/QR patterns
does not mean reusing its cryptographic domains or its device-link protocol.

## Proposed implementation ownership

Keep the implementation in separately reviewable changes; the coordinator
continues to own `STATE.md`.

| Work | Primary files |
|---|---|
| Sync prerequisite | New per-conversation recovery model/storage; `mobile/lib/sync/sync_recovery.dart`, `storage/local_store.dart`, encrypted database and `core/app_state.dart`; native service transaction changes only if the reviewed design requires them |
| C0 prerequisite | New numbered server/local migrations; `server/internal/storage/community_store.go`, `mls_group_store.go`, message validation/transport; Flutter community/channel models, selection and projections |
| C1 server domain/storage | Prefer a new membership-invitation service/store file for authorization and transitions; reuse transaction helpers, admission limits and scoped events; extend community storage for username join and atomic removal |
| C1 HTTP | `server/internal/httpapi/api.go`, new membership-invite handlers, narrow changes to `conversation_handlers.go`; handlers decode/authorize/delegate, domain logic remains outside HTTP |
| C1 Flutter | New invite/request models and coordinator/service; small `api_client.dart` / `app_state.dart` integration; `features/communities/community_screen.dart`, new community details/request views, existing `features/chat/conversation_details_screen.dart` |
| Encrypted naming | W11/C3 implementation files, scoped metadata adapters into C1 UI; no new plaintext fields |
| Tests/evidence | Focused new Go store/API tests, Flutter parser/service/widget/native integration tests, then `testing/evidence/C1-membership.md` |

Do not edit W8-owned shared files concurrently. Once W8 is integrated, name
one implementation owner for `app_state.dart`, `models.dart`,
`api_client.dart`, application payloads and local schema; other agents can
review or own tests in disjoint files.

## Acceptance and security checks

- Exact invite round-trip: secret stays after `#`; malformed/foreign-origin
  links fail without echoing secret input; requests carry only the reviewed
  proof/locator. Inspect HTTP and logging fields directly.
- Request/approval state machine: outsiders, wrong scope, self-escalation,
  higher/equal-role targets, suspended/deleted accounts, expiry/revocation,
  duplicate request, approval races, use limits and bounded pending rows.
- No access before approval/Welcome: envelopes, attachments, private channel
  lists, key-package claims, old epochs and history remain inaccessible.
- Real native MLS lifecycle: approval leads to the exact Welcome/add set;
  concurrent epoch changes retry without merging rejected commits; one
  removal affects all and only required groups; last owner cannot disappear.
- Poisoned community cannot stop a separate DM/group from syncing; the
  failed group's durable quarantine survives restart and bounded recovery.
- Shared-channel context cannot be substituted or omitted; open channels
  share one group, private channels do not; multi-channel join cost follows
  the measured C0 model rather than one commit per open channel.
- Group/community lists, usernames, decisions, renamed encrypted metadata,
  leave/removal and pending-MLS statuses are usable in Flutter on Windows;
  parser/service/widget tests and live Go/Rust/Flutter integration exercise
  success and rejection cases.
- Run narrow checks first, then required `scripts/test` and `scripts/lint`.
  The coordinator has recorded current Windows cleanup/fsync limitations in
  L0 evidence; do not call C1 complete until its required checks or CI pass.

## Owner decisions and external blockers

No new dependency, account or service is required merely to implement the
existing group/community membership UI and server state machine.

Owner D51 settles C0's metadata question: the server may see channel IDs for
posting/retention, while posts and names remain encrypted. Busy-channel
separation stays at C8's measurement stage; neither needs another product
question to prepare C1. Concrete prerequisite designs are
[scoped sync](C1-sync-isolation.md) and
[data-preserving C0 migration](C0-preserving-migration.md).

Any implementation that needs a new library waits for the owner's dependency
approval and license/notices review. Do not turn the unresolved C0/W11/C3
questions into silent wire-format or key-policy choices.
