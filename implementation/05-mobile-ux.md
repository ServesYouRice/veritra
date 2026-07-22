# Plan 05 — Complete the mobile experience

UI cards depend on a green Flutter baseline. Message-content work waits for C09.
Every visual card requires widget tests plus manual screenshots at phone,
large-text, and tablet widths.

## U01 — Render trustworthy conversation identity

Audit references: UI-03, UI-01.

Depends on: M01, M04, C09 for decrypted sender display.

Objective:
Replace generic DM/group labels and short account IDs with authorized,
unambiguous identity.

Steps:

1. Extend Dart models for the peer/member summary returned by M04/M01.
2. Render DM peer username and deterministic initials/avatar.
3. Render group/channel title plus member count where useful.
4. Resolve sender display name in group bubbles without exposing metadata to
   nonmembers.
5. Define deleted/unknown identity states.
6. Add duplicate-name, long-name, deleted-account, RTL, and accessibility
   tests.

Acceptance:

- Multiple DMs are visually distinguishable.
- A user can identify the recipient before sending.
- Screen-reader labels name the peer/conversation once.
- Generic account IDs are a fallback detail, not the primary identity.

## U02 — Add backward message-history pagination

Audit references: UI-04, LOG-08.

Depends on: C03, Y04.

Objective:
Load all authorized history with stable cursor merging and scroll position.

Steps:

1. Add per-conversation page state: oldest cursor, loading, error, and end.
2. Fetch next_before when the user nears the top.
3. Merge by message ID and stable order without replacing newer local rows.
4. Preserve scroll position while prepending.
5. Persist pages in the encrypted database with a bounded eviction policy.
6. Test more than 200 messages, duplicate pages, expired rows, retry, and
   concurrent realtime arrivals.

Acceptance:

- History older than the newest page is reachable.
- Repeated or overlapping pages create no duplicate bubbles.
- Loading, retry, and end-of-history states are visible and accessible.

## U03 — Add authenticated message actions

Audit reference: UI-11.

Depends on: C09, Y01, Y02.

Objective:
Expose edit, delete, react, and reply through an accessible action surface.

Steps:

1. Define permissions and time/state restrictions from server plus decrypted
   authenticated payload state.
2. Add a long-press action sheet and an explicit semantics/overflow alternative.
3. Implement delete first, then edit, reply, and reactions.
4. Use optimistic states only where rollback is unambiguous.
5. Render pending, failed, edited, deleted, reply, and unsupported-version
   states.
6. Test offline, duplicate, forbidden, stale-epoch, and screen-reader use.

Acceptance:

- Users can delete their message through a visible privacy control.
- No action trusts unauthenticated server-visible hints.
- Gesture-only users have an equivalent button/menu path.

## U04 — Repair metadata search and navigation

Audit reference: UI-07.

Depends on: M04.

Objective:
Make every promised search result accurate, navigable, and privacy-scoped.

Steps:

1. Align copy with actual account, community, and channel result types.
2. Keep exact-match account search to prevent directory enumeration.
3. Reuse the canonical DM instead of creating duplicates.
4. Navigate community and channel rows deterministically, loading required
   data when absent from cache.
5. Remove claims that conversation titles are searched unless the API adds
   that scoped metadata.
6. Add empty, partial, stale-cache, and dead-end navigation tests.

Acceptance:

- Every enabled result row has a working destination.
- No tap creates a duplicate DM.
- Search never touches message ciphertext or plaintext content.

## U05 — Make community channel rows consistent

Audit reference: UI-08.

Objective:
Use one canonical channel navigation surface and remove inert duplicates.

Steps:

1. Map each community channel to its backing conversation.
2. Make the channel row within the community card open it.
3. Remove or repurpose the duplicate “Channels you are in” section.
4. Show a clear unavailable state when mapping is incomplete.
5. Add loading, empty, many-channel, and navigation widget tests.

Acceptance:

- Every visually interactive channel row opens or explains why it cannot.
- Channel information is not duplicated without a distinct purpose.

## U06 — Fix forms and connect-screen polish

Audit references: UI-09, MERGE-01, corrected Fable UI-12.

Objective:
Make validation accurate, visible, and consistent with server byte rules.

Steps:

1. Replace the mojibake sequence in connect_screen.dart with a real en dash.
2. Keep “12–72 UTF-8 bytes”; do not change the rule to characters.
3. Revalidate password confirmation when the source password changes.
4. Keep change-password validation inside the dialog and show success/failure.
5. Require a documented group title/member minimum in API and UI, or explicitly
   document self-group behavior.
6. Replace phone-useless localhost prefill with an empty HTTPS-oriented hint,
   while keeping deliberate loopback development possible.
7. Do not add a mounted guard before the current insecure-URL dialog solely
   for the rejected false positive; there is no await before showDialog.

Acceptance:

- No mojibake remains in source or rendered UI.
- Password validation matches server UTF-8 byte behavior.
- Invalid forms stay open with actionable inline errors.
- New-group rules agree between API and client.

## U07 — Make push, mute, receipts, and connection state honest

Audit references: UI-10, UI-11, NICE-07.

Depends on: Y07.

Objective:
Tell users what delivery signals exist and expose privacy-relevant controls.

Steps:

1. Model offline, reconnecting, syncing, last-synced, queued, sent-to-server,
   and failed states from durable facts.
2. Show a compact connection banner without claiming end-to-end delivery.
3. Show platform/provider-specific push status, especially “no iOS background
   notifications” until APNs exists.
4. Add the existing per-conversation mute preference to details.
5. Either expose opt-in read-receipt controls and visible receipt benefit, or
   stop emitting receipts until the UI exists.
6. Keep notification payload copy generic.

Acceptance:

- Users can distinguish queued/offline from accepted by server.
- Push absence/failure is visible and repairable.
- Mute and receipt behavior is explicit and test-covered.

## U08 — Complete responsive and accessibility verification

Audit references: UI-13, UI-14, TEST-11.

Objective:
Add tablet master-detail behavior and verify core flows with assistive
technology and large text.

Steps:

1. Build a stable list/detail layout at the existing rail breakpoint.
2. Preserve selected conversation, back behavior, focus, and state across width
   changes.
3. Add semantics tests for auth, chat list, chat, message actions, member
   management, and settings.
4. Test 200 percent text scale, narrow phones, tablets, RTL, keyboard, and
   reduced motion.
5. Run manual TalkBack and VoiceOver passes on real devices.
6. Review screenshots for clipping, duplicated text, contrast, and viewport
   overflow.

Acceptance:

- Core actions remain reachable at every tested size.
- No long-press-only control lacks an explicit accessible alternative.
- Final decrypted message text is readable/selectable by screen readers.
- Manual device results are recorded with platform versions.

