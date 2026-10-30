# W8: silent phone wakes and local mention notices

Independent design review, 2026-10-27. **Proposed, not implemented.** The
owner approved generic silent wakes for muted conversations (D52, recorded
by the coordinator). This does not authorize plaintext push data or changing
the production crypto gate. No new dependency is needed for this design.

## Review result

Removing the mute filter alone is unsafe and incomplete. Current code:

- `server/internal/storage/push_wake_store.go` checks mute at enqueue,
  claim and immediate pre-delivery refresh. Every check needs the same
  capability-aware condition; changing only enqueue does not deliver wakes.
- FCM already sends data only, with normal priority. APNs already uses
  `content-available:1`, background push type and priority 5. The provider
  payload has no sender/message text; it does not itself request an alert.
- Android `PushEventBridge.markWake` immediately shows
  `GenericNotification` when unfocused. iOS `didReceiveRemoteNotification`
  immediately schedules a generic alert while inactive, then completes its
  callback. Neither waits for decryption or knows whether a message mentions
  this account.
- Dart `_handlePushEvent`, `_catchUpSyncEvents`, `_runOwnedCatchUp`,
  `_observePendingWake` and acknowledgement deliberately require foreground.
  The paused-wake test proves that present behavior.
- `MobilePushService` has no local-notice or background completion method.
  The desktop notifier already filters committed local text/mentions, but
  is not attached on phones.
- There is no headless engine, native scheduled job or background Dart sync
  coordinator. A native event sink with no running Dart listener only leaves
  a persisted generation for the next foreground launch.

Therefore a complete implementation is native lifecycle work plus a bounded
Dart owner, not a payload flag. Until it is built and tested, do not advertise
muted-phone mentions as complete or opt a subscription into extra wakes.

## Subscription capability and backwards safety

The server-only capability/provider slice is implemented in migration 0040;
see [D52 server evidence](../../testing/evidence/D52-server-silent-wakes.md).
Current clients continue registering in legacy mode. Native readiness and
the remaining lifecycle work below must pass before any client opt-in.

Add one subscription-scoped enum column, default `legacy_generic`, to
`push_subscriptions`; proposed other value: `local_decrypt_v1`. Allocate its
migration number through the coordinator. Add an optional registration field
`notification_mode` with that closed set of values. Omitted means legacy,
including on an upsert: an old app re-registering must reset its old mode.
Never infer capability from provider, account, app version text or another
device's registration.

The native method channel reports readiness only after the compiled native
silent path and shared-engine job coordinator are installed. Dart then
registers its background completion handler and confirms readiness for the
current profile. Only a build using the already-authorized MLS demo wiring
may request `local_decrypt_v1`. `UnavailableCryptoService` never opts in.
Persist enough native profile/registration association to resume that same
profile; never scan or unlock another account in response to a push.

For legacy registrations retain current mute filtering and payload/notice
behavior. For opted-in registrations send **all** wakes silently, muted or
unmuted. A push cannot safely be changed into an alert based on a later mute
race, and the server cannot know whether encrypted text contains a mention.

Use a distinct payload version so an old native handler cannot mistake the
extra wake for a legacy alert:

```json
{"version":"v2","event":"new_encrypted_event_available","presentation":"none"}
```

No conversation ID, sender, mention bit, content or ciphertext goes into
this payload. FCM remains data-only/normal priority. APNs retains only
`content-available` in `aps`, plus those generic custom fields. UnifiedPush
uses the same generic v2 payload after transport decryption. Do not promote
all such wakes to high priority: many result in no user-visible notice.

At enqueue/claim/refresh, muted conversations are eligible only when the
**current target subscription** has `local_decrypt_v1`. All block, membership,
disabled-target and revoked-device checks remain. Resolve the current mode
again immediately before provider send. A queued muted wake whose subscription
has reverted to legacy is dropped/deferred under the original mute filter,
never delivered as a visible legacy wake.

Propagate mode through `PushWakeJob`, `RefreshPushWakeJob`, `push.Notification`,
all providers and test-push handling. Test push is still a wake; for opted-in
clients it must not claim that an alert was shown merely because delivery
succeeded. Coalesce jobs per subscription where safe: a generic wake asks for
catch-up, not one notification per server event.

## One process, one engine and one AppState

Use one cached `FlutterEngine` and its one `AppState` per process for UI and
background work. Normal UI entry and a cold background delivery both acquire
that engine from a native owner manager; they do not each instantiate one.
Generated plugins and the push/storage channels register once per engine.

Android needs an application-level engine manager used by both `MainActivity`
and a new SDK `JobService`. Move push bridge installation out of Activity-only
setup. UI permission prompts/distributor pickers stay Activity-only; the job
does not request permissions or open UI. Background delivery records the wake
generation and schedules/coalesces a normal network-constrained JobScheduler
job, then the FCM/UnifiedPush service callback returns quickly. The job owns
the platform work lifetime, not an untracked Dart future.

iOS needs an application-level cached engine owner used by the APNs callback
and the scene's Flutter view controller. Current storyboard/implicit-engine
startup must be adjusted so scene presentation attaches to the cached engine
rather than silently creating a second engine. Factor channel/plugin
installation so background startup does not depend on an already-initialized
implicit UI engine. Keep LaunchScreen behavior separate from main view setup.

Execute the **normal compiled root entry point** when creating the cached
engine. A demo binary therefore reaches real MLS only through `main_demo`;
a release binary still reaches `main.dart`/`UnavailableCryptoService`. Do not
add a native callback that constructs `NativeCryptoService` independently.
Use the same existing profile namespace and transport policy. Never treat
null/detached Flutter lifecycle as resumed during a headless cold start:
`VeritraApp.initState` currently falls back to resumed and needs an explicit
native launch-context/attached-view distinction.

This singleton is security relevant: `LocalSyncLease.key` currently consists
of origin/account/device/generation. Two new engines can both start at the
same generation, and `acquireSyncLease` replaces the row rather than acquiring
an exclusive lock. It is not sufficient cross-engine ownership. Do not ship
a second engine and assume that lease prevents MLS ratchet races. Retain
existing profile locks, serialized native operations and transaction CAS as
defense in depth; use an opaque unique owner nonce if owner tokens are changed.

## Bounded background work

Add an explicit short-lived background permit; do **not** set `_isForeground`
to true. It must bind current session/profile generation, native work ID,
observed wake generation, monotonic deadline and cancellation state. The
existing `AccountSyncEngine` remains the sole catch-up owner and coalesces
foreground/background triggers. Foreground resume hands off through that
owner and drains cancelled work before starting a replacement.

Proposed application budget: stop starting new work after 20 seconds, with
a native hard completion deadline before iOS's 30-second allowance. Cap
pages/events/bytes per pass; refresh only data needed for authenticated
decryption and notification eligibility. Android JobService may be stopped
earlier and forwards cancellation. No attachment auto-downloads, websocket
reconnect loops, new calls, background read receipts, permission prompts or
unbounded outbox flushing are started by this pass.

Use cancellable request deadlines derived from remaining budget. Existing
15/30-second API timeouts are not an adequate per-job bound. `Future.timeout`
alone does not cancel network or in-flight work: abort the specific request,
recheck permit/session before the next event and before durable mutation,
and stop at an atomic boundary. Do not force-destroy the engine or release
its sync lease while a crypto/storage operation is still running. A native
expiration/stop callback cancels further work; the atomic transaction and
existing state rollback rules handle abrupt OS termination safely.

Cold startup opens **existing** protected state only. Missing/unavailable
Keystore/Keychain keys, a locked/protected file, unknown profile, unavailable
crypto, sync recovery, cancelled ownership or failed authentication yields
no notice and leaves the wake pending. Do not create a replacement database
key, reset storage, re-link, downgrade protection or invoke interactive
recovery from a job. iOS currently uses `first_unlock_this_device`; preserve
that protection and defer when this device has not yet unlocked.

Completion reports `newData` only for durable newly applied data, `noData`
for successful no-op and `failed` for incomplete/error work. iOS holds its
completion handler until that result (or expiration), calling it once.
Android calls `jobFinished` once after durable work, or handles `onStopJob`
without racing a late completion. Only acknowledge the observed persisted
wake generation when catch-up and required notification decisions finish;
newer wakes or budget exhaustion remain pending for another OS opportunity
or foreground resume. Background work must not enter device-wide recovery
merely because protected storage is temporarily inaccessible.

## Local notification after authenticated decryption

Share the pure eligibility logic with the desktop notifier, not its
`DesktopShell` dependency. Examine only text rows already committed with MLS
state, sender/context checks and message effects. Reuse the W8 decoration
parser and match the authenticated `account_id` mention entity to this
session's account; never use raw `@name` text or a push hint.

Reject own messages, invalid/unsupported/hidden/action/deleted/expired rows,
blocked senders, unaccepted message requests and stale catch-up messages.
Refresh mute policy within the remaining budget; on failure stay quiet.
An ordinary muted message never alerts. A valid account mention may override
mute only when the local `mentionsInMutedChats` setting permits it. A policy
decision must not send read receipts or download attachment previews.

Add native `showLocalGenericNotice(workId, notificationId)` on the existing
method channel. Native code validates current work ownership, permission,
deadline and lack of an active UI before reusing the fixed generic Android/
iOS notification content. No plaintext message or sender string is passed
through this call. v2 raw wake handlers **never** invoke the generic alert.

Persist a small notification-decision outbox with the message/state commit
or an equivalent crash-safe marker; a process killed after decryption must
not silently lose the only mention candidate. Deduplicate by a stable opaque
message/event ID and use a stable native notification ID so retry replaces
the same notice. Clear expired/deleted candidates, bound queue size and
notification batch count, and retain no extra plaintext. Foreground resume
may finish pending decisions but must not raise stale or duplicate notices.

## What can be implemented and what needs evidence

All described primitives are available from existing Flutter, Android SDK,
Foundation/UIKit/UserNotifications and the current plugins. No WorkManager,
background-service or notification plugin is necessary. **They are not yet
wired here:** a server-only flag, a v2 parser, or a warm-Dart test is not the
complete phone path.

Current workstation has no Android SDK at the inspected standard location
and no Mac/Xcode runtime. Native platform code can be written and built in
the existing Android/iOS CI jobs; actual phone lifecycle evidence still needs
configured FCM/APNs or UnifiedPush and devices. Do not confuse a missing local
SDK with a required new dependency or new product decision.

Delivery remains best effort even after correct implementation. Apple may
delay/coalesce/throttle background notifications and grants limited callback
time; force quit/kill can discard held updates. Android normal-priority FCM
can wait for Doze maintenance, and its receive callback has only a short
processing window. OS force-stop/restrictions can prevent work. Pending
generations ensure catch-up on next allowed execution; no design can promise
instant muted mentions while the OS refuses to run the app. See
[Apple background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app),
[Firebase Android priority](https://firebase.google.com/docs/cloud-messaging/android/message-priority)
and [Android JobService](https://developer.android.com/reference/android/app/job/JobService).

## Required checks before opt-in

- Server tests cover default/omitted/upsert downgrade, separate devices,
  all three mute checks, mute changes while queued, block/revoke races,
  provider payload exact fields, silent APNs/FCM delivery and coalescing.
- Dart tests prove legacy paused wakes still defer, only valid bounded
  permits allow work, duplicate wakes coalesce, logout/expiry cancels,
  background sync never marks read, and failed keys/storage stay quiet with
  the generation pending. Deadline cancellation leaves no late mutation.
- Native/integration tests prove raw v2 produces no alert; only a committed
  eligible mention reaches the local notice call; ordinary muted/request/
  blocked/deleted/expired messages stay silent; dedupe and crash-after-commit
  notification recovery work.
- Cold killed-process delivery and warm paused delivery use the same engine/
  state; UI resume during a job cannot create a second owner or lose MLS
  state. Exercise iOS completion/expiration exactly once and Android stop/
  retry, permission denial, before-first-unlock, Doze and force-stop limits.
- Build Android/iOS with release crypto markers intact. Keep capability
  disabled until the native path and tests pass; do not label mobile mention
  alerts complete based only on Dart/Go unit tests.
