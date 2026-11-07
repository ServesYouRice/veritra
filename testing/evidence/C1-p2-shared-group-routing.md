# C1 prerequisite 2: shared-group routing (C0)

Branch `agent/c1-p2`, migration 0049. Switch
`PRIVATE_MESSENGER_COMMUNITY_LAYOUT` (default off).

## Built

- **Schema (0049, additive).** `community_layouts`,
  `community_conversation_layouts`, `community_channel_routes`; one `legacy`
  layout row per existing community. No conversation, message, membership or
  channel row is changed.
- **Server (`community_layout_store.go`).**
  - With the switch on, `CreateCommunity` makes the shared conversation
    (physical kind `community_channel`, no channel, projected as
    `community_shared` in list, by-id and retention responses).
  - Open and announcement channels are routes to it; a private channel gets
    its own conversation with its creator only, and others are added through
    the existing conversation member route (community members only).
  - `ManageCommunityMember` in an active layout joins the shared conversation
    only. The shared roster cannot be edited directly; a hand-made
    `community_channel` conversation is refused.
  - Message admission: a post in the shared conversation must carry
    `crypto_metadata.channel_id` (an open/announcement route of that
    conversation) and `community_layout_generation` (current). The keys are
    refused everywhere else. Announcement refusal uses the route.
    Replies and threads stay in their channel; edits and deletes keep the
    stored channel. Wrong or missing context answers 400
    `invalid_crypto_metadata` (an existing code; no new error code).
  - `GET /communities/{id}/channels` returns `conversation_id`,
    `layout_version`, `layout_generation`; a private route is listed only to
    members of its conversation.
- **App.** Models for the new fields; `ChannelRoutedCryptoService`
  (`encryptChannelPayload`) puts the channel and generation in the clear
  metadata and the channel in the encrypted payload (W7 receive side already
  existed); AppState captures the selected channel before awaiting, fails
  closed without one, filters timeline, pending sends and pins per channel;
  Communities opens a channel as (group, channel); the shared group is hidden
  from the chat list; a forward into it is refused.

## Checks

Go, local: `go test ./...` (all packages), `go vet ./...`, `gofmt -l`.
New tests: `server/internal/storage/community_layout_test.go` (migration
leaves rows unchanged and is repeatable; switch off is unchanged; routes,
projection, one shared membership per join, private visibility, bypasses,
substitution/omission/foreign/private/stale route, announcement refusal,
replies, edit/delete, member limit) and
`server/internal/httpapi/community_layout_test.go` (HTTP codes).

Dart: `dart format --language-version=3.4` clean on every changed file.
`flutter analyze` and `flutter test` were not run locally (no Flutter SDK);
the PR's CI runs them. New test: `mobile/test/c0_shared_group_routing_test.dart`.

## Not built (and why)

- **Cutover of legacy communities.** Needs the signed layout control record
  and a native signing domain (an ABI bump this package does not own). Legacy
  communities stay legacy.
- **Encrypted channel names.** Names stay the legacy plaintext column until
  C3/W11; the new routes add no new plaintext field.
- **Per-channel unread, search jump and composer drafts** inside the shared
  group: unread and drafts are still per group; a search hit opens the group
  on the last selected channel.
- **Residual trust.** Routes are server-asserted until the signed record
  exists; the encrypted `channel_id` stops the server moving a post between
  channels, not hiding or inventing a channel.
- **Counters.** Migration 0049 only; no local schema; no crypto ABI change.

## Review fixes (PR #136)

| Blocker | Problem | Fix | Test |
| --- | --- | --- | --- |
| B1 privacy | `SearchMetadata` listed a private channel's id and name to every community member. | The channel branch applies the `listChannelsQuery` rule: a private route is listed only to members of its conversation. | `TestActiveLayoutSearchHidesPrivateChannelsFromNonMembers` |
| B2 authorization | A member demoted in the community kept admin in private channels, because the role loop covered only the shared conversation. | `ManageCommunityMember` also sets the new role on the target's existing private-channel memberships and emits `membership.updated` for each. It adds no row, so it never grants access. Option (a) was chosen; refusing kind `private` until C3 can still be layered on. | `TestActiveLayoutDemotionReachesPrivateChannelRoles` |
| B3 admission | A repeated top-level `channel_id` key passed admission (Go keeps the last) but SQLite `json_extract` (first) read another channel from the stored row. | Admission in a shared group, and edits of a shared-group message, refuse metadata that repeats a top-level key. The metadata is still stored byte for byte, so idempotent retries still match. | `TestActiveLayoutRefusesARepeatedChannelKey` |

There is no community remove or leave path in storage (`RemoveConversationMember`
refuses community conversations), so no removal path needed the B2 change.
