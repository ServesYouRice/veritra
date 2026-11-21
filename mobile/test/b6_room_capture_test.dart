import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/room_capture.dart';
import 'package:private_messenger/calls/room/room_foreground_service.dart';
import 'package:private_messenger/calls/room/room_ports.dart';

// B6 platform capture: which platform can send what, and the order of the
// consent steps before a screen capture (Android 14 refuses a projection
// without its foreground service, and the service before the consent).

class FakeService implements RoomForegroundService {
  FakeService(this.log, {this.allow = true});
  final List<String> log;
  final bool allow;
  @override
  Future<bool> startScreenShare() async {
    log.add('service start');
    return allow;
  }

  @override
  Future<void> stop() async => log.add('service stop');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> log;

  PlatformRoomCapture capture(
    TargetPlatform platform, {
    bool consent = true,
    bool service = true,
    Future<List<ScreenSource>> Function()? sources,
  }) =>
      PlatformRoomCapture(
        platform: platform,
        service: FakeService(log, allow: service),
        requestCapturePermission: () async {
          log.add('consent');
          return consent;
        },
        listSources: sources,
      );

  setUp(() => log = []);

  group('what each platform can send', () {
    test('iOS sends a camera but not a screen (O6)', () {
      final c = capture(TargetPlatform.iOS);
      expect(c.canUseCamera, isTrue);
      expect(c.canShareScreen, isFalse);
      expect(c.screenNeedsSource, isFalse);
    });

    test('Android shares its screen through the system consent', () {
      final c = capture(TargetPlatform.android);
      expect(c.canShareScreen, isTrue);
      expect(c.screenNeedsSource, isFalse);
    });

    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      test('$platform picks a screen or window in the app', () {
        final c = capture(platform);
        expect(c.canShareScreen, isTrue);
        expect(c.screenNeedsSource, isTrue);
      });
    }

    test('iOS refuses to begin a screen share even if asked', () async {
      final c = capture(TargetPlatform.iOS);
      expect(await c.beginScreenShare(), isFalse);
      expect(log, isEmpty);
    });

    test('a build with no capture is voice only', () async {
      const c = NoRoomCapture();
      expect(c.canUseCamera, isFalse);
      expect(c.canShareScreen, isFalse);
      expect(await c.beginScreenShare(), isFalse);
    });
  });

  group('screen share steps', () {
    test('Android: consent first, then the service, in that order', () async {
      final c = capture(TargetPlatform.android);
      expect(await c.beginScreenShare(), isTrue);
      expect(log, ['consent', 'service start']);
      await c.endScreenShare();
      expect(log.last, 'service stop');
    });

    test('Android: a refused consent never starts the service', () async {
      final c = capture(TargetPlatform.android, consent: false);
      expect(await c.beginScreenShare(), isFalse);
      expect(log, ['consent']);
    });

    test('Android: a service the platform refuses means no capture', () async {
      final c = capture(TargetPlatform.android, service: false);
      expect(await c.beginScreenShare(), isFalse);
      expect(log, ['consent', 'service start']);
    });

    test('Android: an error in the consent cleans up and refuses', () async {
      final c = PlatformRoomCapture(
        platform: TargetPlatform.android,
        service: FakeService(log),
        requestCapturePermission: () async => throw StateError('no activity'),
      );
      expect(await c.beginScreenShare(), isFalse);
      expect(log, ['service stop']);
    });

    test('macOS asks for the capture permission, no service', () async {
      final c = capture(TargetPlatform.macOS);
      expect(await c.beginScreenShare(), isTrue);
      expect(log, ['consent']);
      await c.endScreenShare();
      expect(log, ['consent'], reason: 'only Android has a service');
    });

    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      test('$platform needs neither consent nor service', () async {
        final c = capture(platform);
        expect(await c.beginScreenShare(), isTrue);
        expect(log, isEmpty);
      });
    }
  });

  group('desktop sources', () {
    test('lists screens and windows', () async {
      final c = capture(
        TargetPlatform.linux,
        sources: () async => const [
          ScreenSource(id: '0', name: 'Screen 1'),
          ScreenSource(id: '9', name: 'Notes', isWindow: true),
        ],
      );
      final sources = await c.screenSources();
      expect(sources.map((s) => s.isWindow), [false, true]);
    });

    test('a capturer that fails lists nothing, never throws', () async {
      final c = capture(
        TargetPlatform.linux,
        sources: () async => throw StateError('no display'),
      );
      expect(await c.screenSources(), isEmpty);
    });

    test('phones list nothing: the system picks', () async {
      final c = capture(
        TargetPlatform.android,
        sources: () async => const [ScreenSource(id: '0', name: 'x')],
      );
      expect(await c.screenSources(), isEmpty);
    });
  });

  group('foreground service channel', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(PlatformRoomForegroundService.channelName);

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('asks native for the mediaProjection type and reads true', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return true;
      });
      expect(await PlatformRoomForegroundService().startScreenShare(), isTrue);
      expect(seen!.method, 'start');
      expect(seen!.arguments, {'mediaProjection': true});
    });

    test('anything but an explicit true is a refusal', () async {
      final service = PlatformRoomForegroundService();
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await service.startScreenShare(), isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await service.startScreenShare(), isFalse);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'not_allowed'),
      );
      expect(await service.startScreenShare(), isFalse);
    });

    test('a missing plugin refuses the share and stop never throws', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final service = PlatformRoomForegroundService();
      expect(await service.startScreenShare(), isFalse);
      await service.stop();
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'x'),
      );
      await service.stop();
    });

    test('stop is sent to native', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      await PlatformRoomForegroundService().stop();
      expect(calls, ['stop']);
    });
  });
}
