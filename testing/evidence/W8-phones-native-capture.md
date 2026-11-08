# W8 phones (D52): native capture switch - 2026-11-07

Phone mention notices are **on by default in demo builds** (owner decision,
2026-11-08) and **cannot be turned on in release/profile builds**. Nothing is on in release builds. No phone or
Xcode was available: Kotlin and Swift are compiled by GitHub CI only, and no
warm/cold phone lifecycle run exists.

## What decides "on"

`--dart-define=VERITRA_DEMO=true`; `--dart-define=VERITRA_PHONE_NOTICES=false` opts a demo build out.

- Android: `build.gradle.kts` reads Flutter's `dart-defines` Gradle property and
  sets `BuildConfig.VERITRA_PHONE_NOTICES`; the `release` and `profile` build
  types force it false. `WakeWorkerCoordinator.COLD_EXECUTION_ENABLED` and the `install`
  reply's `can_opt_in` follow it.
- iOS: `PhoneNoticeBuild` reads `DART_DEFINES` via the `VeritraDartDefines`
  Info.plist key, which only `Debug.xcconfig` fills (Release/Profile empty); `coldExecutionEnabled` and `install`'s
  `can_opt_in` follow it. Release is always false.
- Dart: `main.dart` is untouched. Only `main_demo.dart` builds its bridge with
  `allowOptIn`, so any other bridge still treats `can_opt_in:true` as a bad reply.
  `bootstrap` still always says false.

## Flow (demo build with the switch on)

UI start -> after sign-in `_startPush` installs the native worker for the
compiled profile -> if native says `can_opt_in` -> notice capture on -> push
registers with `notification_mode: local_decrypt_v1`. Every endpoint rotation
re-registers with the same mode (the server resets a registration that omits
it; this builds on the TASK-012 pending-endpoint path). A cold background start
installs first, then `allowPhoneNotices()`, and the restore turns capture on.
Sign-out/session reset turns both off; a failed install or capture keeps the
registration generic.

## Checks (Linux, Flutter 3.44.0; JDK)

- `flutter analyze`: no issues; `dart format`: clean.
- Dart tests: `wake_worker_bridge` (demo bridge accepts opt-in only after a
  successful install and loses it on uninstall; default bridge still refuses),
  `push_state` (no mode by default; mode on pending record and on rotations;
  refused/throwing install sends none), `w8_background_wake` (capture follows
  opt-in; without it nothing is captured or alerted).
- JVM `WakeRulesTest`: 56 checks (install reply follows the flag, bootstrap
  never offers opt-in). `wake-tests/` is not wired into CI; run by hand.

## Not checked

Android/iOS builds and lifecycle (Doze, quota, kill, iOS expiration, notification
permission denied, logout during a job) - see the W8 evidence list.  The Swift parser test lives in `RunnerTests.swift`; CI does not run the Xcode test target.

A demo UI that gets `can_opt_in:false` from native uninstalls its worker, so a
build without the native flag cannot run warm background catch-up.
