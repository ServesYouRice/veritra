# W8 message actions — 2026-10-27

Status: client implementation and focused verification in place; independent
review/full-script verification and the D52 phone background path remain open.
No commit, push or release performed. Production messaging gates remain closed.

## Implemented

- Composer formatting becomes plain text plus UTF-16 ranges: bold, italic,
  strike, inline/block code and spoilers. Receivers drop malformed decoration
  entries individually. Mentions name current roster accounts; desktop notices
  use the shared on-device eligibility policy, including the muted-mention
  preference. Edits and hidden/deleted/expired content cannot raise notices.
- Text/reply forwards become fresh text messages, retain formatting and drop
  mentions, quotes and source identity. Forward count is capped at five chats,
  or one for a message already forwarded five times. Attachment forwards decrypt
  into memory and re-encrypt with a fresh key/nonce/AAD and upload per destination;
  only ciphertext temporary files are written. Plaintext buffers are wiped.
- DM members and cached group moderators can pin for 1, 7 or 30 days. Pins use
  server envelope time, are capped by the message expiry, and keep at most three
  entries per conversation/channel. A durable applied order resolves equal
  timestamps and survives backup. The pin bar, unpin action and expiry are local
  projections of encrypted messages.
- Stars, delete-for-me, archived chats and five pinned chats persist on this
  device. Delete-for-me clears content, attachment keys, decorations, reactions,
  pins and stars, and later actions cannot restore it. Archived chats stay
  archived on new messages. Message actions scroll on small windows; right-click
  works through selectable text, and starred messages are browsable in the chat.

## Protocol and persistence

The W7/C0 context rules apply to v2 payloads. Unchanged bodies still use v1;
every server-visible envelope keeps `payload_version: 1` for VAP1 framing.
No formatting, mentions, pin type, forward source or local preferences enter
server plaintext. Unknown additive v2 fields are ignored; reserved poll/profile/
moderation types remain unsupported. Targeted actions check conversation,
channel, author/role, hidden/deleted state and expiry on both store paths.

Local schema 13 adds the W8 message columns and pin/star/preference tables;
backup plaintext v4 reads v1-v3. New columns are installed before old generated
backfill reads, and the upgrade remains one transaction. Synthetic older-version
fixtures strip W8 additions before setting their old schema version.

`local_pending_pins` is separate from message formatting. This device cannot
decrypt its own MLS echo, so a pin command waits for that matching echo. The
cursor transaction rechecks current authority, applies server time, and consumes
the command even when an intervening demotion denies it. Duplicate echoes cannot
replay a consumed command. Same-device backup preserves a command with a queued
outbox or still-pending authenticated own action row, including the HTTP-ack to
sync-echo gap. K2 history transfer must exclude pending commands entirely.

The original composer draft is a local-only encryption argument. It is cleared
atomically even when markup is stripped; a forwarded message cannot clear the
destination's existing draft.

## Checks

Real checks run on Windows with the pinned Flutter SDK and the built native
`private_messenger_crypto.dll`:

**Final focused run: 138 passed, 0 failed, 0 skipped, 36 seconds.** It used
`flutter test --no-pub --concurrency 1 --timeout 30s` over the four W8 test
files, `native_outbox_test`, `receive_policy_test`, `desktop_shell_test`,
`message_notice_policy_test`, `message_history_test`, `message_search_test`,
`scoped_rebuild_test`, `attachments_test`, `attachment_crypto_test`,
`app_payload_test` and `message_expiry_test`, with the real native DLL enabled.

- `w8_message_actions_test.dart`: memory and SQLite effects, invalid ranges and
  surrogate boundaries, compatibility/context, authority, hidden-target guards,
  capped pin expiry, deterministic ties, v3/v4 backup, local limits, own echo,
  backup across HTTP acknowledgement, and transaction-failure retry.
- `w8_migration_test.dart`: actual schema12-to13 content preservation and failed
  migration rollback followed by successful retry.
- `native_outbox_test.dart`: real MLS encryption/outbox/HTTP/native receive,
  formatting/mentions, pin and text forward, identical metadata, forward limits,
  raw-draft clearing/preservation, and demotion between send and own echo.
- `w8_forward_attachments_test.dart`: real multi-chunk (>1 MiB) two-destination
  forward, fresh keys/ciphertexts/contexts, memory-only encrypt/decrypt and buffer
  wiping. It also checks authentication failure and cancellation cleanup.
- `w8_ui_test.dart`, desktop/shared notice policy and existing history/search,
  receive-policy and attachment regressions exercise real widgets and storage.
- Full Dart analysis passed. Drift models and localization output were generated
  using the pinned tools; Serbian Latin remains generated from Cyrillic.

The coordinator passed `scripts/test.sh` and `scripts/lint.sh` on an isolated
Linux snapshot; see the full Linux verification section below. Earlier Windows full-store fixtures have two known
backup-exclusion path assertion failures. Closed SQLite test connections and
released fixture locks remove the unrelated Windows teardown failures in the
focused history/receive-policy suites without changing production lock lifetime.

## Remaining gates and limits

- D52 generic silent muted-phone wakes are approved, but Android/iOS background
  decryption and notice delivery are a separate coordinated prerequisite. This
  implementation does not claim sleeping-phone mention delivery is complete.
- Group pin authorization still reads cached server roles (W7 S4). C4 moves
  that source into encrypted group state. This is an integrity residual, not
  permission for server plaintext or hidden-device history access.
- Local stars/preferences/deletion are device-local. No account-wide settings
  sync, poll/moderation payload activation or release-gate bypass was added.

## Full Linux verification (2026-10-28)

The isolated full test and lint scripts now pass. See
[`verification-2026-10-28.md`](verification-2026-10-28.md) for scope, counts
and log hashes. This supersedes the earlier lack of a Linux fallback; the
Windows-specific failures and platform evidence limitations remain.

## Owner decisions and D52 Dart integration (2026-10-31)

**Pins (owner, 31 Oct).** Any member of a DM or group may pin; community
conversations keep moderator roles. Up to **50** active pins per chat (per
channel in a shared community conversation); the 51st evicts the oldest. The
pin bar shows about three rows and scrolls. One rule (`pinAllowed`,
`pinLimitPerChat` in `crypto/message_format.dart`) feeds sender, receiver,
own-echo, memory, SQLite and K2 import paths. The admin-only switch for
groups is **left for C4**: groups have no encrypted settings record yet.
Mixed versions disagree until updated (older apps drop member pins in groups
and keep 3). Group name/photo: open to any member by default, admins may
restrict later (C4); recorded in W11 open question 4. No group profile
editor exists yet, so no code changed for it.

**Linux "done when".** A muted chat's account mention raises a desktop
notice after decryption, and a plain message in that chat does not; the
switch in Settings turns mention alerts off. Proven end to end through
AppState catch-up → `onMessagesPublished` → `MessageNotifier`
(`w8_background_wake_test.dart`, Linux desktop test). The six desktop
notice tests in `desktop_shell_test.dart` had been failing since the D52
timestamp-substitution check; their fixtures now use matching row times.

**Phones (D52), Dart side wired behind the guard.**

- `push/notice_decisions.dart`: notice outbox → policy (fresh mute read,
  blocks, D48 acceptance, shared mention rule) → frozen opaque decision →
  native generic notice → terminal state. Unknown policy data keeps the
  reference pending; a lost native answer retries the same decision ID.
- `AppState.restoreForBackgroundWake` / `catchUpForBackgroundWake`: one
  AppState and one sync owner per process; existing state only; bounded
  crypto calls fenced by the permit; job-owned HTTP client closed on
  cancel; no websocket, push registration, outbox, key-package publish,
  reconcile/revocation commit, wake ACK, recovery record or sign-out from
  the background. UI resume cancels the wake, suppresses captured
  references through the committed cursor and runs the deferred work.
  Sign-out revokes native work and capture before private state is cleared.
- `main_demo.dart` builds the store/AppState once for both launches; a cold
  background start opens existing state only and is never "resumed".
  `main.dart` is unchanged (release never installs a worker).

**Still off, deliberately.** `noticeCaptureEnabled` is never set by app
code; registration still omits `notification_mode`; native
`COLD_EXECUTION_ENABLED`/`coldExecutionEnabled` stay false and both native
replies say `can_opt_in:false`. So no phone gets muted-mention wakes yet.

**What a real device must still show before enabling** (in this order):
1. Android and iOS builds (normal and demo) with release markers intact; the
   Swift engine/scene changes have never been built (no Xcode here).
2. A reviewed change that sets capture on and registers
   `local_decrypt_v1` only after `install` succeeds for the compiled
   profile, and flips the native cold-execution/`can_opt_in` flags.
3. On phones: warm paused and cold killed delivery share one engine/AppState;
   UI resume during a job; Android `onStopJob`/retry, Doze, quota and
   force-stop; iOS completion exactly once, expiration, before-first-unlock;
   notification permission denied; logout during a job; dedupe after a crash
   between decision and OS notice; muted/request/blocked/deleted/expired
   messages stay silent; raw v2 pushes never alert by themselves.
4. Independent review of the Dart integration (this change) alongside the
   native slices.

Checks (Linux, pinned Flutter 3.44.0, debug native library built here):
`w8_background_wake_test.dart` 25 passed (18 processor cases on memory and
SQLite, 6 AppState wake cases, 1 Linux desktop case); with the regression
set (`app_state`, `receive_policy` real MLS, `background_wake_runner`,
`notice_outbox`, `wake_launch_coordinator`, `desktop_shell`,
`message_notice_policy`, `sync_service`, `push_state`, `session_switch`,
`native_notice_capture`, `sync_recovery`, `demo_profile`, `native_outbox`,
`outbox_delivery`, `mls_outbox`) 230 tests ran: all passed except one
`sync_recovery_test` case that failed once under host load and passed in
three reruns (alone and in a smaller batch). Pin change: `w8_ui`,
`w8_message_actions`, `native_outbox`, `k2_history_snapshot` pass.
`flutter analyze`: no issues. The full `scripts/test`/`scripts/lint` were
not run (shared 4-CPU host; brief limits to touched and related tests).
`scripts/check-demo-boundary.sh` still fails only on `api_client.dart` and
`device_link_v3_models.dart`, which another agent owns.
