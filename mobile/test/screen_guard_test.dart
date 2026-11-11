import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/screen_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformScreenGuard', () {
    late List<MethodCall> channelCalls;
    late MethodChannel testChannel;
    late PlatformScreenGuard guard;

    setUp(() {
      channelCalls = <MethodCall>[];
      testChannel = const MethodChannel(PlatformScreenGuard.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, (call) async {
        channelCalls.add(call);
        if (call.method == 'isSecure') {
          return true;
        }
        return null;
      });
      guard = PlatformScreenGuard(channel: testChannel);
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, null);
    });

    test('on Android, setSecure invokes method channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await guard.setSecure(true);
      expect(channelCalls, hasLength(1));
      expect(channelCalls.first.method, 'setSecure');
      expect(channelCalls.first.arguments, <String, Object?>{'secure': true});

      await guard.setSecure(false);
      expect(channelCalls, hasLength(2));
      expect(channelCalls.last.method, 'setSecure');
      expect(channelCalls.last.arguments, <String, Object?>{'secure': false});
    });

    test('on Android, isSecure invokes method channel and returns result',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final result = await guard.isSecure();
      expect(result, isTrue);
      expect(channelCalls, hasLength(1));
      expect(channelCalls.first.method, 'isSecure');
    });

    test('on non-Android, setSecure and isSecure do not invoke method channel',
        () async {
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        channelCalls.clear();

        await guard.setSecure(true);
        expect(channelCalls, isEmpty);

        final result = await guard.isSecure();
        expect(result, isFalse);
        expect(channelCalls, isEmpty);
      }
    });

    test('platform exceptions fail closed and do not throw', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, (call) async {
        throw PlatformException(code: 'error', message: 'test exception');
      });

      // Does not throw.
      await guard.setSecure(true);
      final isSec = await guard.isSecure();
      expect(isSec, isFalse);
    });

    test('missing plugin exception fails closed and does not throw', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, (call) async {
        throw MissingPluginException();
      });

      // Does not throw.
      await guard.setSecure(true);
      final isSec = await guard.isSecure();
      expect(isSec, isFalse);
    });
  });

  group('FakeScreenGuard', () {
    test('tracks secure state and history', () async {
      final fake = FakeScreenGuard();
      expect(await fake.isSecure(), isFalse);
      expect(fake.history, isEmpty);

      await fake.setSecure(true);
      expect(await fake.isSecure(), isTrue);
      expect(fake.history, [true]);

      await fake.setSecure(false);
      expect(await fake.isSecure(), isFalse);
      expect(fake.history, [true, false]);
    });
  });
}
