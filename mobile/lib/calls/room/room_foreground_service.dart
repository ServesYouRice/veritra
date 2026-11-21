import 'package:flutter/services.dart';

/// The Android foreground service a screen share needs (B6, design "Mobile
/// and desktop constraints"). Android 14 and later refuse a screen capture
/// unless a foreground service of type `mediaProjection` runs, and refuse to
/// start that service before the user has accepted the capture consent. The
/// service shows one fixed notification with no names (like I41) and exists
/// only while a screen share does; the microphone and camera need none while
/// the app is in the foreground (O5).
abstract interface class RoomForegroundService {
  /// Starts the service. False when the platform refuses it (not allowed in
  /// this app state, build without the service, plugin missing): the caller
  /// must then not share the screen.
  Future<bool> startScreenShare();

  /// Stops it. Never throws.
  Future<void> stop();
}

/// [RoomForegroundService] over the native `room_call_service` channel
/// (`RoomCallService.kt`). Anything but an explicit `true` from native is a
/// refusal, so a missing plugin or an error fails closed.
class PlatformRoomForegroundService implements RoomForegroundService {
  PlatformRoomForegroundService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'org.veritra.private_messenger/room_call_service';

  final MethodChannel _channel;

  @override
  Future<bool> startScreenShare() async {
    try {
      return await _channel.invokeMethod<bool>('start', <String, Object>{
            'mediaProjection': true,
          }) ==
          true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Nothing to stop, or already stopped.
    } on MissingPluginException {
      // A build without the service has nothing running.
    }
  }
}
