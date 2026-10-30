# D52 native platform preparation - 2026-10-29

Guarded native implementation; **phone opt-in and cold execution remain off**.
This is not completed sleeping-phone mention delivery. The production crypto
gate and normal compiled Dart entry points remain unchanged.

## Implemented boundaries

- Android shares one process-owned FlutterEngine between MainActivity and the
  SDK JobService. Native channels install once; UI permission/distributor work
  requires the attached Activity. A job never selects an entry point/profile
  from push data, never opens an Activity and never starts a foreground service.
- FCM and decrypted UnifiedPush accept only the exact three-field v2 silent
  payload. It persists a wake marker and schedules normal network-constrained
  JobScheduler work. It cannot fall back to the legacy generic alert.
- Native sequence is separate from pending generation and survives ACK/logout.
  Overflow, corrupt values and failed durable writes fail closed. Stale ACKs
  cannot clear a later generation reused as1. A failed SharedPreferences ACK
  restores the old pending value even when commit(false) already changed its
  in-memory map; the job requests retry. iOS ACK journal I/O failure retains
  pending state and completes the OS callback as failed, distinct from durable
  SQL catch-up. A newer-generation mismatch keeps the newer marker intact.
- Monotonic permits expire within20s, deduct startup time, bind profile and
  generation, and revoke before cancellation/completion. Job stop and late
  results cannot acknowledge or notify with a revoked permit. UI resume shares
  the same engine and revokes background ownership.
- Native notice attempts record an opaque per-profile ID durably **before** OS
  scheduling. Retry returns suppressed. Up to4096 fresh IDs are retained for an
  hour (Dart eligibility freshness is10min); full/corrupt/unwritable journals
  fail closed and never evict a fresh ID. A persisted clock highwater refuses
  rollback. Android additionally sets OnlyAlertOnce. A crash after recording
  an attempt can miss its generic alert; it does not repeat the alert. Message
  storage/cursor correctness is separate from this deliberate attempt policy.
- The typed `wake_worker_bridge.dart` enforces the protocol, one channel owner,
  profile/permit/generation/budget bounds and sanitized errors. An early UI-only
  observer creates no storage/worker and survives failed worker installation.
  Metadata/journal read failure returns native-fixed launch/current-UI facts
  with null binding and native_silent:false; it cannot authorize cold work or
  block an actual UI launch from opening its own protected store.
- iOS source now uses one explicit headless-capable engine with SceneDelegate
  UI attachment, retains the launch storyboard and removes implicit Main
  storyboard engine creation. A notification launch hint cannot turn scene
  connection alone into UI/key initialization. Actual foreground UI attaches
  to the same root. This Swift change has **not** been built here.
- iOS source includes a first-unlock, backup-excluded, atomic file/rename and
  file/directory-fsynced metadata journal, held APNs completion callbacks and
  delivered/pending local-notice identifier checks. These platform behaviors
  require Xcode and phone lifecycle verification before activation.

Native `COLD_EXECUTION_ENABLED` / `coldExecutionEnabled` are false. Both native
bootstrap/install replies advertise `can_opt_in:false`; the bridge refuses a
premature true result. Root owns the separate existing-only protected-store
bootstrap, bounded Dart catch-up, actual HTTP cancellation, notification-decision
outbox and AppState handoff. Native installation alone cannot enable capability.

## Checks

Installed JDK21, targeting Java17:

```text
javac --release 17 -d build/native-wake-jdk <WakeRules.java> <WakeRulesTest.java>
java -cp build/native-wake-jdk org.veritra.private_messenger.WakeRulesTest
PASS:44 assertions
```

The standalone Java test exercises exact silent payload allowlisting, invalid
fields, retained sequence/overflow, monotonic deadlines, revoked/stale permits,
native-fixed UI/background bootstrap facts on metadata failure, exact durable-result identity, failed-commit in-memory ACK restoration and retry,
journal-before-OS crash/reload, duplicate attempt
suppression, fresh capacity refusal, expiry and wallclock rollback.

Pinned Flutter3.44.0:

```text
flutter test --no-pub --concurrency 1 test/wake_worker_bridge_test.dart
PASS:6,0 failed,0 skipped
dart analyze lib/push/wake_worker_bridge.dart test/wake_worker_bridge_test.dart
PASS:no issues
```

Bridge tests exercise actual MethodChannel encoding in both directions,
bootstrap, bounded invocation, single-owner/concurrent-run refusal, cancellation,
exception sanitization, retry, no opt-in authorization and UI-only observation
without a profile or working native worker.

Android native compile uses the pinned repository Gradle9.1.0/AGP9.0.1/Kotlin
2.3.20 and Flutter SDK, with its configured NDK28.2.13676358:

```text
flutter pub get --enforce-lockfile
bash gradlew --no-daemon --max-workers=1 \
  -Dorg.gradle.jvmargs='-Xmx768m -XX:MaxMetaspaceSize=384m' \
  -Pkotlin.compiler.execution.strategy=in-process \
  :app:compileDebugKotlin :app:compileDebugJavaWithJavac -x compileFlutterBuildDebug
```

The Kotlin and app Java tasks pass in an isolated Linux source snapshot with
2GiB container memory. This intentionally checks native sources without a Dart
APK build. The initial actual Kotlin attempt found a missing EventChannel import;
it was fixed and subsequent native compiler runs pass. Earlier wrapper/shell
startup failures are not counted as code checks. Existing Gradle/plugin
deprecation warnings remain; no dependency/version was changed.

Snapshot source hashes: `D52-android-source-sha256.json` beside this evidence.
Ignored local artifacts: `build/native-kotlin-final-current.log`,
`build/native-compiled-source-sha256.json`; retained SDK/build container
`veritra-native-platform-final-20261029` and source volume
`veritra-native-platform-source-20261029`. Compilation is serialized because
parallel Windows/Rust/Flutter processes previously exhausted host memory.

Not checked: normal/demo Android APK packaging, emulator/real-phone warm/cold
lifecycle, OS kill/Doze/quota behavior, any iOS build or APNs lifecycle. No Mac or
Xcode is available. Repository-wide checks and independent native peer review
remain coordinator-owned; none of these checks satisfies human G25 review.
