# D52 native wake contract, protocol 1

2026-10-29. Coordinator-reviewed contract; guarded native implementation is in
progress. Server mode0040 is separate. This contract does not enable subscription opt-in. No new
dependency, background Dart entrypoint, crypto constructor or key generator.

## Bootstrap and one owner

CI pins Flutter 3.44.0; iOS deployment target is 13. Android uses Flutter's
pinned minSdk and SDK JobScheduler APIs available from API21.

Android: process singleton `SharedFlutterEngine`, created only on the main
looper, installs process-owned native channels before executing Dart.
`MainActivity.provideFlutterEngine(Context)` and `VeritraWakeJobService`
retrieve that same object; `shouldDestroyEngineWithHost()` returns false.
Activity teardown never destroys the shared engine. Generated plugins are
registered once, not again when an Activity attaches. UI-only operations
(permission request/distributor picker) require the attached Activity and
never run from a job. FCM/UnifiedPush event delivery is posted to main.

iOS: AppDelegate lazily owns one explicit
`FlutterEngine(name:project:allowHeadlessExecution:)`. It runs the compiled
root `main` once, with nil library URI; plugins/storage/push channels register
once. SceneDelegate remains a FlutterSceneDelegate and creates its one
FlutterViewController using that engine. Remove both Main storyboard entry
settings from Info.plist to prevent an implicit second engine; retain the
launch-screen storyboard. Scene connection forwards the Flutter scene
lifecycle and attaches the existing engine even after cold background work.
No engine is created merely by `didFinishLaunching`: first UI scene or a
permitted background callback requests it. Multiple scenes remain disabled.

Native never selects `main_demo.dart`, a Dart library URI, a namespace, or
entrypoint arguments from a push/preferences. The normal compiled root is
used in every case. Root Dart determines its fixed compiled profile; native
only reports an advisory previous binding for comparison. A mismatch fails
closed. Release `main.dart` retains unavailable crypto; only compiled
`main_demo.dart` constructs NativeCryptoService and retains D11/D12.

**Prerequisite before enabling cold execution:** root must query bootstrap
before constructing/opening storage. Current main/main_demo unconditionally
restore, and SecureLocalStore can create a missing key. A cold wake must use
the existing-only key/database path, no login, key creation, registration,
permission prompt, outbox send or second AppState. Until root installs this
guard plus the bounded worker, native background execution/readiness stays
disabled. Root owns these Dart main/AppState/storage/transport changes.

## Exact method channel

New bidirectional MethodChannel:
`org.veritra.private_messenger/wake_worker`.
Existing push_methods/push_events retain their legacy API. All maps below
have `protocol:1`; unknown protocols/malformed fields fail closed. No payload
contains a server origin, account, sender, channel, text, key, or token.
`profile` is the compiled Dart local-store namespace, never a filesystem path.

Dart to native:

- `bootstrap` (no arguments) ->
  `{protocol:1,launch:"ui"|"background",bound_profile:String|null,
  ui_attached:bool,native_silent:bool,can_opt_in:false}`.
  Launch is fixed when this engine starts; UI attachment is current.
  This call creates no profile/key/database and returns no secret. If the
  notification metadata/journal cannot be read, preserve native-fixed launch
  and current UI facts but return null binding and native_silent:false; never
  infer background readiness or block a real UI because of wake metadata.
- The typed Dart bridge also provides `observeUiAttachment(callback)`, a
  local incoming-handler registration with no native request, profile, storage
  or worker. It lets a quiet headless root enter normal UI setup once when its
  cached engine later receives `uiAttached`. Until `install`, `run` returns
  unavailable. Worker installation preserves this observer unless replaced.
- `install` `{protocol:1,profile:String}` ->
  `{protocol:1,native_silent:true,worker_attached:true,can_opt_in:false}`.
  Caller installs its incoming handler first and invokes this only after
  compiled-profile validation and existing-only bootstrap readiness. It is
  idempotent for this process/profile; another profile conflicts. Native
  rejects a second in-process owner, and stores only the advisory binding.
  This is worker wiring, not authorization to register server opt-in.
- `uninstall` `{protocol:1,profile:String}` -> bool. Revoke active permits,
  cancel scheduled work, complete held OS callbacks once as failed/no-data,
  clear this profile's pending marker/binding, retain monotonic sequence.
  Existing `unregister` invokes the same invalidation.
- `validatePermit` `{protocol:1,permit:String,profile:String}` ->
  `{active:bool,remaining_ms:int}`. It can shorten/deny work and never extends
  a permit. An expired/stopped/mismatched permit returns false/0.
- `presentGenericNotice`
  `{protocol:1,permit:String,profile:String,notice_id:String}` ->
  `"shown"|"suppressed"|"unavailable"`. Notice ID is canonical lowercase
  hex32 of a stable local decision identity. Native requires a live permit,
  matching profile, unexpired monotonic deadline, background UI state and
  notification permission. It displays only the existing fixed generic
  sentence. Android derives a stable notification integer from this opaque
  digest; iOS uses a fixed prefix plus digest. No arbitrary title/body/sound
  or conversation identifier is accepted. Permission refusal never prompts.
  Native additionally keeps a durable per-profile journal of opaque notice IDs.
  Record an ID **before** calling the OS notifier. Retry of a consumed ID is
  suppressed. This deliberately gives at-most-once attempts: a crash between
  journal commit and OS scheduling can miss a generic alert, but cannot repeat
  its sound. Message/cursor data is unaffected. Retain up to4096 fresh IDs for
  one hour (worker content freshness is ten minutes); never evict a fresh ID to
  make room. Full/unwritable/corrupt journals fail closed. A retained clock
  highwater refuses attempts after wallclock rollback. Android also uses
  `setOnlyAlertOnce`; iOS checks delivered/pending stable identifiers before
  scheduling. No journal entry contains content, origin, account or sender.

Native to Dart:

- `run` `{protocol:1,permit:String,profile:String,wake_generation:int,
  budget_ms:int,deadline_epoch_ms:int}` ->
  `{protocol:1,permit:String,profile:String,wake_generation:int,
  outcome:"committed"|"no_change"|"retry"|"unavailable"}`.
  Permit is a fresh opaque UUID, at most one active per process. Budget is
  1..20000ms and includes engine/worker startup; epoch deadline is advisory
  for Dart scheduling. Native separately enforces elapsed monotonic time.
  Profile/generation must exactly match. Committed means catch-up and its
  local notification-decision outbox are durable. No-change is also a
  durable eligible catch-up decision. Retry/unavailable never ACK a wake.
- `cancel` `{protocol:1,permit:String,profile:String,
  reason:"deadline"|"os_stop"|"unregistered"}` -> bool.
  Native revokes first, then sends this signal. Dart must actively abort
  permit-owned HTTP requests, cancel its sync permit and prevent subsequent
  state mutations; Future.timeout alone is insufficient. Root owns actual
  HTTP cancellation and the atomic AppState/MLS commit fence. Late run
  results and local-notice requests are ignored/refused.
- `uiAttached` `{protocol:1,attached:bool}` (notification, result ignored)
  informs bootstrap/UI coordination without constructing another owner.

Default platform implementation exposes `can_opt_in:false`. Enabling that
capability is a separately reviewed change after bounded Dart installation
and actual Android/iOS build/lifecycle evidence. An unsupported method,
worker missing, locked/missing key, profile mismatch or unavailable release
crypto stays quiet and leaves the wake pending. No legacy fallback alert for
v2 is permitted.

## Durable marker and OS lifetime

Maintain a monotonically increasing native sequence separately from pending
generation. ACK only removes a matching pending marker; it never resets the
sequence, preventing an old ACK from clearing a later generation numbered 1.
Preserve legacy pending marker migration. Overflow/storage failure fails
closed. Android uses synchronous SharedPreferences.commit with result checks. Because
commit(false) can already have changed its in-memory map, failed ACK restores
its prior pending generation and schedules retry; it never overwrites a newer
marker. iOS ACK I/O failure leaves the journal marker and reports failed OS
completion even when the independent SQL catch-up transaction committed.
iOS needs a small atomic, backup-excluded native wake-state journal (sequence,
pending, advisory profile only), with file/directory sync before treating a
marker as durable; no ciphertext, plaintext cache or credential is stored.
Use first-unlock file protection; failure before unlock stays silent.

Android raw v2 handlers validate the exact generic three-field payload,
persist generation and schedule one coalesced JobScheduler job with network
ANY and normal backoff. Never display from that callback. A running job
coalesces new generations in the marker rather than replacing its active job.
onStartJob returns true, gets the shared engine and obtains one <=20s permit.
onStopJob revokes/cancels before returning true for retry; it does not call
jobFinished afterward. Normal completion calls jobFinished exactly once;
retry/new generation requests reschedule. Deadline completion cannot ACK.
No persisted-reboot job/boot receiver/foreground service/high priority is
introduced. Existing UI startup still observes any pending generation.

iOS raw v2 callback persists generation and retains its completion closure
until a matching durable run outcome. Each callback has a hard native timer;
total handling stays below Apple's 30s allowance, with at most 20s of worker
budget and startup deducted. Use ProcessInfo.systemUptime for monotonic
fencing. Complete `.newData` for committed, `.noData` for durable no-change,
`.failed` for retry/unavailable/deadline. Exactly once, even if timeout and
Dart result race. Never extend a callback with another wake. Callbacks whose
generation is newer than the completed permit remain pending for a bounded
next catch-up, or finish failed when their own deadline expires. No repeated
UIBackgroundTask extension or polling loop claims extra execution time.

Legacy v1 retains its existing generic behavior and foreground wake path.
V2 never directly invokes GenericNotification/UNUserNotificationCenter alert.
Only post-decrypt notice outbox decisions can call the local notifier. Shared
engine UI resume suppresses notices while preserving the same sync owner.

## Limits, verification and ownership

APNs background pushes are throttled and not guaranteed; iOS grants up to
30s when it actually delivers one. Android jobs can be deferred/stopped by
OS quota/network/Doze, and force-stop prevents expected execution until user
launch. Persisted markers and normal UI catch-up provide retry, not guaranteed
instant alerts after killed/throttled delivery. Never advertise otherwise.

This agent would own Android MainActivity/push services, new shared-engine/
job/coordinator classes and manifest; iOS AppDelegate/SceneDelegate/Info.plist
and coordinator/journal helper; push_service.dart typed bridge/tests only.
No AppState/storage/native-crypto edits. Native readiness stays off until
root's bootstrap/worker meets this contract and platform checks pass.

Check warm/cold UI attach uses one engine, v2 parser never alerts, stale/late
permit cannot notify/ACK, sequence survives ACK/restart, profile mismatch,
OS stop vs completion exactly once, new generation during run, startup cost
deduction, keys unavailable, denied permission, UI resume/logout during work.
Build normal and demo Android/iOS under pinned Flutter, retaining ABI/release
markers. Simulator builds alone do not prove real-phone background execution.

Primary API references checked for this proposal:

- [FlutterActivity cached/provided engine API](https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html).
- [FlutterEngine iOS lifecycle/default main library](https://api.flutter.dev/ios-embedder/interface_flutter_engine.html).
- [Flutter UIScene adoption](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate).
- [Android JobService start/stop/completion](https://developer.android.com/reference/android/app/job/JobService).
- [Apple background push limits](https://developer.apple.com/documentation/UserNotifications/pushing-background-updates-to-your-app).
