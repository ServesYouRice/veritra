import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'room_foreground_service.dart';
import 'room_ports.dart';

/// The platform side of camera and screen capture for a room (B6): what the
/// platform can capture, and the consent steps that come before a capture is
/// created. [RoomMediaSession] runs the fail-closed publish after them.
abstract interface class RoomCapture {
  bool get canUseCamera;

  /// iOS can watch a screen share but not send one (O6): its broadcast
  /// extension is not built.
  bool get canShareScreen;

  /// Desktop picks the screen or window in the app; Android uses the system's
  /// own consent screen.
  bool get screenNeedsSource;

  /// The screens and windows a desktop can share, or none.
  Future<List<ScreenSource>> screenSources();

  /// Everything that must happen before the screen track is created: the
  /// system's capture consent (Android, macOS) and, on Android, the
  /// `mediaProjection` foreground service, in that order. False means do not
  /// capture.
  Future<bool> beginScreenShare();

  /// Undoes [beginScreenShare]'s service. Never throws.
  Future<void> endScreenShare();
}

/// A build with no capture: voice only.
class NoRoomCapture implements RoomCapture {
  const NoRoomCapture();
  @override
  bool get canUseCamera => false;
  @override
  bool get canShareScreen => false;
  @override
  bool get screenNeedsSource => false;
  @override
  Future<List<ScreenSource>> screenSources() async => const [];
  @override
  Future<bool> beginScreenShare() async => false;
  @override
  Future<void> endScreenShare() async {}
}

/// `flutter_webrtc`'s capture paths, by platform:
///  - Android: `getDisplayMedia` uses MediaProjection. The consent comes from
///    `Helper.requestCapturePermission` (asked afresh every time, because
///    Android 14 refuses to reuse a consent), and the foreground service
///    starts only after it.
///  - Windows, macOS, Linux: libwebrtc's desktop capturer, with the source
///    chosen from `desktopCapturer.getSources`. macOS asks for Screen
///    Recording permission. Linux captures on X11; Wayland through the
///    PipeWire portal is not confirmed (S1).
///  - iOS: camera only (O6).
class PlatformRoomCapture implements RoomCapture {
  PlatformRoomCapture({
    TargetPlatform? platform,
    RoomForegroundService? service,
    Future<bool> Function()? requestCapturePermission,
    Future<List<ScreenSource>> Function()? listSources,
  })  : _platform = platform ?? defaultTargetPlatform,
        _service = service ?? PlatformRoomForegroundService(),
        _requestPermission = requestCapturePermission ?? _consent,
        _listSources = listSources ?? _desktopSources;

  final TargetPlatform _platform;
  final RoomForegroundService _service;
  final Future<bool> Function() _requestPermission;
  final Future<List<ScreenSource>> Function() _listSources;

  bool get _desktop =>
      _platform == TargetPlatform.windows ||
      _platform == TargetPlatform.macOS ||
      _platform == TargetPlatform.linux;

  @override
  bool get canUseCamera => true;

  @override
  bool get canShareScreen => _desktop || _platform == TargetPlatform.android;

  @override
  bool get screenNeedsSource => _desktop;

  @override
  Future<List<ScreenSource>> screenSources() async {
    if (!_desktop) return const [];
    try {
      return await _listSources();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> beginScreenShare() async {
    if (!canShareScreen) return false;
    try {
      if (_platform == TargetPlatform.android ||
          _platform == TargetPlatform.macOS) {
        if (!await _requestPermission()) return false;
      }
      if (_platform == TargetPlatform.android) {
        // After the consent, before the projection (Android 14).
        return await _service.startScreenShare();
      }
      return true;
    } catch (_) {
      await endScreenShare();
      return false;
    }
  }

  @override
  Future<void> endScreenShare() async {
    if (_platform == TargetPlatform.android) await _service.stop();
  }

  static Future<bool> _consent() => rtc.Helper.requestCapturePermission();

  static Future<List<ScreenSource>> _desktopSources() async {
    final sources = await rtc.desktopCapturer.getSources(
      types: [rtc.SourceType.Screen, rtc.SourceType.Window],
    );
    return [
      for (final source in sources)
        ScreenSource(
          id: source.id,
          name: source.name,
          isWindow: source.type == rtc.SourceType.Window,
        ),
    ];
  }
}
