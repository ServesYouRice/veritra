import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Screen guard abstraction for protecting app screens against AI-assistant
/// screen reading, screen recording, and screenshots (Android FLAG_SECURE).
abstract class ScreenGuard {
  Future<void> setSecure(bool secure);
  Future<bool> isSecure();
}

/// Production implementation of [ScreenGuard] using the platform method channel.
///
/// On Android, this toggles `WindowManager.LayoutParams.FLAG_SECURE` on the
/// main window, preventing screenshots, screen capture, and assistant screen reading.
class PlatformScreenGuard implements ScreenGuard {
  const PlatformScreenGuard({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName =
      'org.veritra.private_messenger/screen_guard';

  final MethodChannel _channel;

  @override
  Future<void> setSecure(bool secure) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(
        'setSecure',
        <String, Object?>{'secure': secure},
      );
    } on PlatformException catch (_) {
      // Platform does not support it or UI is unavailable.
    } on MissingPluginException catch (_) {
      // Channel not registered (e.g. in non-Android or unit test environments).
    }
  }

  @override
  Future<bool> isSecure() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isSecure');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }
}

/// In-memory fake [ScreenGuard] for testing.
class FakeScreenGuard implements ScreenGuard {
  FakeScreenGuard({bool initialSecure = false}) : _secure = initialSecure;

  bool _secure;
  final List<bool> history = <bool>[];

  @override
  Future<void> setSecure(bool secure) async {
    _secure = secure;
    history.add(secure);
  }

  @override
  Future<bool> isSecure() async => _secure;
}
