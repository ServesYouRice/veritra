import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/room_foreground_service.dart';

// B6 screen share and camera on the phones and macOS. These are text checks
// of native code no test here builds (no Android SDK, no Xcode): they catch a
// renamed channel, a moved registration or a manifest entry in the wrong
// build type, not a compile error. The Java rules have a JVM test of their
// own (`android/wake-tests/.../RoomCallRulesTest.java`).

String read(String path) => File(path).readAsStringSync();

void main() {
  const kotlinDir = 'android/app/src/main/kotlin/org/veritra/private_messenger';

  group('Android foreground service for screen share', () {
    test('Kotlin and Dart name the same channel', () {
      expect(
        read('$kotlinDir/RoomCallService.kt'),
        contains(
            'const val CHANNEL = "${PlatformRoomForegroundService.channelName}"'),
      );
    });

    test('the channel is installed before Dart can call it', () {
      final engine = read('$kotlinDir/SharedFlutterEngine.kt');
      final install = engine.indexOf('RoomCallBridge.install(app, messenger)');
      expect(install, greaterThan(0));
      expect(install, lessThan(engine.indexOf('executeDartEntrypoint')));
    });

    test('only the debug manifest declares the service and its permissions',
        () {
      final main = read('android/app/src/main/AndroidManifest.xml');
      final debug = read('android/app/src/debug/AndroidManifest.xml');
      final profile = read('android/app/src/profile/AndroidManifest.xml');
      for (final text in <String>[
        'FOREGROUND_SERVICE',
        'RoomCallService',
        'mediaProjection',
      ]) {
        expect(main, isNot(contains(text)), reason: 'main: $text');
        expect(profile, isNot(contains(text)), reason: 'profile: $text');
      }
      expect(debug, contains('android.permission.FOREGROUND_SERVICE"'));
      expect(
        debug,
        contains('android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION'),
      );
      expect(debug, contains('android:name=".RoomCallService"'));
      expect(
          debug, contains('android:foregroundServiceType="mediaProjection"'));
      expect(debug, contains('android:exported="false"'));
      // Only the mediaProjection type: no microphone, camera or phoneCall
      // service type is declared (O5, and T42B is not approved).
      expect(debug, isNot(contains('foregroundServiceType="microphone')));
      expect(debug, isNot(contains('FOREGROUND_SERVICE_MICROPHONE')));
      expect(debug, isNot(contains('FOREGROUND_SERVICE_CAMERA')));
      expect(debug, isNot(contains('FOREGROUND_SERVICE_PHONE_CALL')));
    });

    test('the build flag is demo-only and forced off for release and profile',
        () {
      final gradle = read('android/app/build.gradle.kts');
      expect(
        gradle,
        contains('val roomServiceBuild = dartDefine("VERITRA_DEMO") == "true"'),
      );
      final release = gradle.substring(gradle.indexOf('release {'));
      expect(
        release.substring(0, release.indexOf('}')),
        contains('"VERITRA_ROOM_SERVICE", "false"'),
      );
      final profile = gradle.substring(gradle.indexOf('configureEach'));
      expect(
        profile.substring(0, profile.indexOf('\n}')),
        contains('"VERITRA_ROOM_SERVICE", "false"'),
      );
    });

    test('the service refuses without its build flag and is never sticky', () {
      final service = read('$kotlinDir/RoomCallService.kt');
      expect(service, contains('BuildConfig.VERITRA_ROOM_SERVICE'));
      expect(service, contains('RoomCallRules.decide('));
      expect(service, contains('START_NOT_STICKY'));
      expect(service, isNot(contains('START_STICKY')));
      // It answers true only after startForeground ran.
      expect(
        service.indexOf('startForegroundNow(mediaProjection)'),
        lessThan(service.indexOf('RoomCallBridge.started(ok)')),
      );
      // The notice carries no name: fixed text from the rules class.
      expect(service, contains('RoomCallRules.NOTIFICATION_TEXT'));
    });

    test('no wake job or push service starts it (D52)', () {
      for (final file in <String>[
        'VeritraWakeJobService.kt',
        'VeritraPushService.kt',
        'WakeWorkerCoordinator.kt',
      ]) {
        expect(read('$kotlinDir/$file'), isNot(contains('RoomCall')));
      }
    });
  });

  group('camera on iOS and macOS', () {
    test('macOS can open the camera and says why', () {
      for (final file in <String>[
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        expect(read(file), contains('com.apple.security.device.camera'));
      }
      expect(read('macos/Runner/Info.plist'),
          contains('NSCameraUsageDescription'));
    });

    // O6: iOS watches a screen share but does not send one in the first
    // release, so there is no broadcast extension and no app group for it.
    test('iOS has no broadcast extension (O6)', () {
      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      expect(project, isNot(contains('com.apple.broadcast-services')));
      expect(read('ios/Runner/Info.plist'),
          isNot(contains('RTCAppGroupIdentifier')));
      expect(
        read('ios/Runner/Info.plist'),
        isNot(contains('RTCScreenSharingExtension')),
      );
    });
  });
}
