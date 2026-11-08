# TASK-012 push endpoint record - 2026-11-07

Android keeps the newest FCM token / UnifiedPush endpoint in private
`veritra_push_state` prefs (`PushEndpointStore`, one `commit()`), with a
generation that only grows. `PushEventBridge.recordEndpoint` writes, then emits
live (live events carry the generation). Listener attach never reads or clears
it. `pendingEndpoint` / `acknowledgeEndpoint` are answered in
`SharedFlutterEngine` (no Activity needed); `unregister` clears the record.
AppState pulls the record after subscribing and loading push config (and on
resume), registers it, and acknowledges only after the server accepted it. A
record for another instance is acknowledged and dropped without upload. Backup
rules already exclude all shared prefs. Nothing logs endpoint, key or secret.

## Checks (Linux, Flutter 3.44.0)

- `flutter test test/push_service_test.dart test/push_state_test.dart test/app_state_test.dart`: all passed
- `flutter analyze`: no issues; `dart format --set-exit-if-changed .`: clean
- JVM: `javac` + `java ...WakeRulesTest`: **WakeRules: 52 checks passed**
  (includes stale endpoint acknowledgement keeping a newer record, overflow).
  `mobile/android/wake-tests` is not run by CI; run by hand.
- Kotlin is compiled only by the GitHub Android job.

## Not done / notes

- Native upload while the app is closed (Q-004) is not built; the record is
  delivered on the next Flutter attach.
- No failing-first run: the new tests need the new API.
- Files outside the prompt's write scope: `SharedFlutterEngine.kt` (owns the
  channel handler), `PushEndpointStore.kt`, `EndpointRules.java`, Dart push
  files and tests (authorized by the coordinator).
