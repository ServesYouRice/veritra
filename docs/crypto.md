# Crypto Boundary

The selected production direction is MLS through OpenMLS. This Rust crate now
pins OpenMLS 0.9.2 and contains a tested native core for signed key packages,
group creation/join, and authenticated application messages. It also exposes a
versioned C ABI and Rust-side credential/key-package boundary types. ABI v6 has
tested opaque device handles, zeroing owned buffers, credential public-key
export, enrollment-challenge signing, key-package creation, state sealing, and
rollback-checked restore, plus group create/join/add/remove/update, staged
membership commits, commit processing, and application encrypt/decrypt. The legacy handle-free
encrypt/decrypt entry points still return `PM_CRYPTO_UNAVAILABLE`, so mobile code cannot
treat the native core as production crypto before the full path is wired and
reviewed.

The server now reserves final account/device IDs before key generation and
atomically verifies and consumes a signed enrollment proof covering the server
challenge, Ed25519 public key, and SHA-256 key-package commitment. The Flutter
client models this preflight, and its low-level Dart FFI binding requires ABI
version 6 exactly (`native_crypto_bindings.dart`) and uses the owned
device/buffer calls. Native libraries are packaged for Android/iOS, while the
production service remains behind the release gate.

The public header is `crypto/rust/include/veritra_crypto.h`, which pins
`PM_CRYPTO_ABI_VERSION` at 6. That version defines:

- account/device-bound opaque handles with exactly-once destruction
- library-owned, zero-on-free output buffers
- enrollment challenge signing with the MLS credential key
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
48 KiB). Passing that check does **not** verify an MLS key package.

OpenMLS 0.9.2, `openmls_rust_crypto` 0.6.0, and their supporting crates are
exactly pinned (Rust 1.91 or newer). All 205 locked third-party packages declare
compatible license choices recorded in `THIRD_PARTY_NOTICES.md`. Sealed state
uses envelope format version 2; version 1 blobs written under OpenMLS 0.8.1 fail
closed. No debug feature that exposes
message content or cryptographic material is enabled.

Before production message sending:

- connect the native ABI to the mobile protected record; the Flutter store now
  atomically writes the 32-byte state key, sealed state envelope, monotonic
  counter, and sync cursor through Android Keystore-backed encrypted storage or
  iOS Keychain (`ThisDeviceOnly`) storage
- add MLS test vectors
- obtain independent protocol and mobile-binding review

## Change log since the Stage 1 freeze

The crypto surface (ABI v5, payload semantics, local schema v7) froze after
Stage 1. Every later change is listed here for the G25 reviewer.

- **Stage 5, I33 (2026-09-24):** no ABI or payload change. Sync stops,
  without advancing the cursor, at any MLS control message it cannot apply,
  and at any application message it cannot decrypt unless the message has
  provably expired. The expired-message tombstone commits only the cursor and
  an `expired:<event>:<target>` marker. The durable recovery record lives in
  local metadata (`sync.recovery`) and holds no content or key material.
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
  builds now send and receive the existing `attachment_manifest` payload.
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
  ratchet, so every retry fails the same way. Any group member can stop
  every other member's sync with one malformed message. Under v2, once MLS
  decryption succeeds, the state and cursor always commit, and the message
  becomes an `unsupported` or `invalid` placeholder row. Unknown non-crypto
  sync event types are skipped rather than fatal. MLS-level failures keep
  the I33 behaviour. The precedent is D25, which already commits a
  sender-mismatched message as `unverifiable`.

## Proposed, not yet built: application payload v2 (W7)

**Status: proposed, not yet built.** This is the W7 design. W8 (message
actions), B3 (polls), W11 (profiles) and later C2/C5 build on it. It
changes nothing until W8 lands. It needs no ABI change: Rust encrypts the
padded payload as opaque bytes, and all of this lives in
`mobile/lib/crypto/app_payload.dart`, `native_crypto_service.dart` and the
local database.

### 1. Receive policy (W8 step 0, lands before any v2 sender)

Today `AppPayloadCodec.decode` throws on an unknown `type`, a `v` other
than 1, extra body fields or a context mismatch. `processApplicationMessage`
then restores the previous MLS state, and sync stops at
`applicationUndecryptable`. Decoding is deterministic, so the retry decrypts
and fails again, and the conversation never moves on. v2 replaces this
with one rule:

> Once `device.decrypt` returns plaintext, the MLS transition and cursor
> always commit, together with exactly one history row.

The row depends on what decoding finds. The checks run in this order:

| Outcome | When | Row kind | Row body | Shown as |
|---|---|---|---|---|
| `invalid` | Framing or UTF-8/JSON broken; `v` not an integer ≥ 1; any of the four context fields missing or not equal to the envelope's (`conversation_id`, `sender_device_id`, `action_id`); or a **known** type at a **known** version whose required fields fail validation | `invalid` (new) | none | A warning: "A message could not be read". Never content |
| `unsupported` | Context matches, and either `v` > 2, or `v` = 2 with a type this app does not know or has not turned on (reserved types, §4) | `unsupported` (new) | The inner JSON exactly as decrypted (≤ 64 KiB, encrypted local database only), so that a later app version can reinterpret it. Reprocessing is a later decision; storing it now is the only chance, because MLS cannot decrypt the message twice | "This message needs a newer version of Veritra" |
| known | Everything validates | As today | As today | As today |

`invalid` and `unsupported` rows never produce effects. Neither counts as
a target (§3), and neither raises a notification.

What stays fail-closed under I33:

- MLS decryption failures;
- control messages;
- sync events that are missing or malformed;
- the expired-message tombstone rule.

Sender mismatch stays as D25 (`unverifiable`). Call signals keep their own
path (`processCallSignal`).

Sync events get the same rule. `_refreshProjectionForSyncEvent` throws
`unsupportedEvent` for an unknown type. In v2, an unknown type that is not
a crypto event (outside `_isCryptoSyncEvent`) is skipped, and the cursor
moves past it. Such events carry no ciphertext and only ask for a refresh,
so skipping one cannot hide content. Unknown `message.envelope.*`,
`mls.*` and `call.*` events still stop sync. W11's `profile.updated` event
depends on this.

**Frozen for every future version:**

- framing: `VAP1`, a big-endian u32 length, the JSON, then random padding
  to a 256-byte bucket, at most 64 KiB in all;
- the six top-level keys: `v`, `type`, `conversation_id`,
  `sender_device_id`, `action_id`, `body`.

A future v3 may add body fields and types, but must keep these, so that a
v2 app can still check context and classify a v3 message as `unsupported`.

### 2. Versions and compatibility

- **Inner `v`.** A sender writes `v: 1` when the payload is a v1 type
  (`text`, `reply`, `edit`, `delete`, `reaction`, `attachment_manifest`,
  `call_signal`) whose body uses only v1 fields. Anything else is `v: 2`.
  A pre-W8 app can then still read plain messages from a W8 app. This
  rule does not reach W11's profile-key sidecar (§5.7): after W11 most
  posts are v2.
- **Decoding v1.** A v2 app decodes `v: 1` exactly as today: the closed
  type set and exact field counts. Those failures are `invalid`.
- **Decoding v2.** Required fields are validated, and **unknown body
  fields are ignored**. A later additive field therefore needs no version
  bump. A change that must not be ignored needs a new type or v3. In v2
  the top-level object must have exactly the six frozen keys.
- **Server-visible metadata.** `crypto_metadata.payload_version` becomes
  the highest version the sending app supports (2), the same on every
  envelope. It must **never** mirror the inner `v`; otherwise the server
  could tell polls, pins or formatted text from plain text. Receivers
  ignore this field. The server does not read it (checked:
  `server/internal` never parses it).
- **Old apps.** No release exists, so there is no deployed base.
  - A pre-W8 demo build receiving any `v: 2` payload still stops at that
    message. Update every demo device when W8 lands.
  - From W8 on, every newer version degrades to `unsupported` rows.
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
2. `conversation_id ==` the action's own `conversation_id`. This is
   **new**: `ReactionEffect` checks no conversation today, and edits and
   deletes check only the sender account. W8 adds the check to every
   targeted effect, the existing ones included;
3. a kind the action allows (table in §4). Today's targetable kinds are
   `text` and `attachment`; v2 adds `poll`. `action`, `invalid`,
   `unsupported` and `unverifiable` rows are never targets;
4. `deleted_at` null. Local delete-for-me (§6) does not count as deleted
   for others' actions; it only hides the row here.

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

| Type | v | Body (required; *optional*) | Who may send (checked by every receiver) | Effect |
|---|---|---|---|---|
| `text` | 1/2 | `text`; *`entities`*, *`mentions`*, *`forwarded`*, *`profile_key`* | Any member | Visible row, kind `text` |
| `reply` | 1/2 | `text`, `reply_to_id`; *`entities`*, *`mentions`*, *`profile_key`* | Any member | Visible row with quote; `reply_to_id` resolved with the §3 rules for display only |
| `edit` | 1/2 | `message_id`, `text`; *`entities`*, *`mentions`* | Target's author account | Replaces text, entities and mentions together. An edit **never** raises a mention alert |
| `delete` | 1 | `message_id` | Target's author account | Clears body and reactions. Kinds widen to `text`, `attachment`, `poll`; clearing an attachment row also drops its keys. A poll's votes and pin go with it |
| `reaction` | 1 | `message_id`, `reaction` (≤ 32 UTF-16 units, empty clears) | Any member | As today, plus the conversation check |
| `attachment_manifest` | 1/2 | `attachments` (≤ 32); *`forwarded`*, *`profile_key`* | Any member | Row kind `attachment` |
| `pin` | 2 | `message_id`, `pinned` (bool); `duration_seconds` when `pinned` is true: 86400, 604800 or 2592000 | DM: either member. Group/channel: moderator roles | §5.4 |
| `poll` | 2 | `question`, `options` (list of strings), `multiple_choice` (bool); *`profile_key`* | Any member | Row kind `poll` (new); body holds the poll JSON |
| `poll_vote` | 2 | `message_id`, `choices` (list of option indexes; empty = retract) | Any member | §5.5 |
| `poll_close` | 2 | `message_id` | The poll's author account | §5.5 |
| `admin_delete` | 2 | `message_id` | Moderator roles; target in the same conversation, any author | **Reserved for C5:** handled as `unsupported` until C5 turns it on. Effect then: as `delete`, shown as "Removed by an admin" |
| `profile_key` | 2 | See [W11](designs/W11-profiles.md#mls-payloads) | Only the subject account's own devices | **Reserved for W11** |
| `group_profile_key` | 2 | See [W11](designs/W11-profiles.md#mls-payloads) | Any member | **Reserved for W11** |
| `call_signal` | 1 | Unchanged | Unchanged | Unchanged |

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
  never fetches a link (B2 is separate).

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

- **Hops.** A forward is a **new** `text` or `attachment_manifest` payload
  in each target conversation, with a new `action_id`. `hops` is the
  source's `hops` plus 1 (0 if the source was not forwarded), capped at
  255. Receivers clamp to 1..255.
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

#### 5.4 Pins

- **Pin and unpin.** `pinned: true` with `duration_seconds` from {1 day,
  7 days, 30 days} pins the target. `pinned: false` unpins it. Expiry
  is the pin envelope's server `created_at` plus `duration_seconds`,
  never the sender's clock, and never later than the target's own
  `expires_at` (W2).
- **Conflicts and limits.** Pins apply in sync order, and the last pin
  action for a target wins. A conversation has at most **3** active pins;
  a fourth evicts the oldest by `pinned_at`.
- **Expiry and deletion.** Expired pins disappear from the pin bar when
  it is drawn, and are swept when the chat opens. Deleting the target,
  for everyone or for this device only, removes its pin here.
- **Old apps.** A pin is an MLS payload, shared by every member. An old
  app shows it as `unsupported` and never as a pin.

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

#### 5.6 Admin delete (reserved for C5)

C5 decides how roles become trusted (C4). Until then the type stays
reserved. The receiver rule is fixed now:

- the sender's role, through the seam, is a moderator role at processing
  time;
- the target passes §3;
- the effect is that of `delete`, with the row marked `removed_by_admin`.

#### 5.7 Profile-key sidecar: `profile_key` field (reserved for W11)

`text`, `reply`, `attachment_manifest` and `poll` may carry
`"profile_key": {"key": "<base64, 32 bytes>", "key_id": "<32 hex>"}`. It
is the sender account's current profile key, so that members who joined
after the sender's last `profile_key` message still learn it. Until W11 it
is ignored, like any unknown field. The rules are in W11.

### 6. Local-only state (never an MLS payload, never sent to the server)

| Feature | Stored as | Notes |
|---|---|---|
| Star | `local_starred(message_key PK, starred_at)` | Removed when the target is deleted or hidden |
| Delete for me | `local_messages.hidden_at` set; body and attachment manifest cleared on this device | Any visible row, also others' messages. Its reactions, pin and poll are hidden here only. Others still see it |
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
| Target key (`message_id`) | 128 characters (current keys are 85) |
| Poll | question 300; 2–12 options of ≤ 100; `choices` ≤ 12 |
| Active pins per conversation | 3 |
| Forward | 5 chats per action; 1 when `hops` ≥ 5 |
| Pinned chats | 5 |

### 8. Local storage when built: schema 10, backup plaintext v3

Action rows store no body, so pin, vote and close state cannot be rebuilt
from history. They are tables applied in the MLS transaction:

| Change | Detail |
|---|---|
| `local_messages`: new nullable columns | `hidden_at`, `forward_hops`, `format_json` (entities and mentions as received), `removed_by_admin` |
| `local_messages`: new kinds | `poll`, `unsupported`, `invalid` |
| `local_pins` | `conversation_id`, `target_key`, `pinned_by_account_id`, `pinned_at`, `expires_at`; PK (`conversation_id`, `target_key`) |
| `local_poll_votes` | `poll_key`, `voter_account_id`, `choices_json`, `updated_at`; PK (`poll_key`, `voter_account_id`) |
| `local_poll_state` | `poll_key` PK, `closed_at` |
| New local-only tables | `local_starred`, `local_conversation_prefs` (§6) |

- **The upgrade** is additive and runs in one transaction, as schema 9
  did.
- **Backup plaintext v3** adds all of the above; v1 and v2 still restore.
  W11 adds its key and profile tables to the same v3, so if W11 builds
  after W8 it bumps to v4. Whichever builds second takes the next number.

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

`H` is the five-key head, followed by `"type":…`:
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
8. `{H,"type":"pin","body":{"message_id":"<T>","pinned":true,"duration_seconds":604800}}`
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
14. `{H,"type":"reaction","body":{"message_id":"<T2>","reaction":"👍"}}`
    gives an `action` row and **no reaction** (a cross-conversation
    target; it fails on today's code).
15. `{H,"type":"sticker","body":{"id":"x"}}` gives `unsupported`. The
    cursor advances, and the JSON is kept.
16. Vector 1 with `"v":3` gives `unsupported`.
17. Vector 1 with `"conversation_id":"conv_99999999999999999999999999999999"`
    gives `invalid`. The cursor advances, and no text is kept.
18. Vector 1 with `"body":{"text":"hi","extra":1}` gives `invalid` (v1
    stays strict).
19. `{H,"type":"text","body":{"text":"hi","future_field":true}}` gives
    `text` "hi" (v2 ignores unknown fields).
20. `{H,"type":"admin_delete","body":{"message_id":"<T>"}}` before C5
    gives `unsupported`.

Encoding: `encode()` writes the keys in this order:

- top level: `v`, `type`, `conversation_id`, `sender_device_id`,
  `action_id`, `body`;
- body: the order of the "Body" column in §4.

Dart's `jsonEncode` keeps insertion order, so vectors 1, 2, 7, 8 and 11
(with `type` moved second) are also byte-exact encode vectors. The test
asserts the bytes between the header and the padding.

Also required:

- **sync tests:** an `unsupported` and an `invalid` message each commit
  the MLS state and the cursor, and the next message in the same
  conversation decrypts;
- **an unknown projection event is skipped;**
- **`native_outbox_test.dart` (I31) covers every new type end to end.**

### 11. Build order

1. **W8 step 0:** the receive policy (§1), the conversation check on
   targets (§3), the `invalid` and `unsupported` kinds, and vectors 1 and
   14–18. It can land alone.
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
