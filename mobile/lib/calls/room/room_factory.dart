import 'dart:async';

import 'package:flutter/foundation.dart';

import 'room_engine.dart';
import 'room_media.dart';
import 'room_ports.dart';
import 'webrtc_frame_keys.dart';

/// [RoomScheduler] on real timers.
class SystemRoomScheduler implements RoomScheduler {
  const SystemRoomScheduler();
  @override
  DateTime now() => DateTime.now();
  @override
  RoomTimer after(Duration delay, void Function() action) =>
      _SystemTimer(Timer(delay, action));
}

class _SystemTimer implements RoomTimer {
  _SystemTimer(this._timer);
  final Timer _timer;
  @override
  void cancel() => _timer.cancel();
}

/// Builds group calls for one signed-in device (demo builds, D11). Each call
/// gets, in this order, and refuses to start without any of them:
///  1. a fail-closed frame key provider ([WebRtcFrameKeys]);
///  2. a call-group handle on a scratch copy of the committed MLS state,
///     never sealed (D70);
///  3. the engine and its media transport.
/// While a call is open the engine is refreshed on a slow poll and whenever
/// [rosterChanges] reports a change in the parent group's members, so a
/// device removed from the conversation is removed from the call too.
class RoomCallFactory {
  RoomCallFactory({
    required this.api,
    required this.crypto,
    required this.selfAccountId,
    required this.selfDeviceId,
    this.rosterChanges,
    this.openKeys = _openKeys,
    required this.connectSfu,
    this.scheduler = const SystemRoomScheduler(),
    this.pollEvery = const Duration(seconds: 2),
  });

  final RoomApi api;
  final RoomCryptoSource crypto;
  final String selfAccountId;
  final String selfDeviceId;
  final Listenable? rosterChanges;
  final Future<WebRtcFrameKeys> Function() openKeys;
  final SfuConnection Function(WebRtcFrameKeys keys) connectSfu;
  final RoomScheduler scheduler;
  final Duration pollEvery;

  static Future<WebRtcFrameKeys> _openKeys() => WebRtcFrameKeys.open();

  final Set<RoomCall> _open = <RoomCall>{};
  bool _closed = false;

  /// Open calls (tests).
  int get openCalls => _open.length;

  Future<RoomCall> open(String conversationId) async {
    if (_closed) throw StateError('the session ended');
    final keys = await openKeys();
    final CallGroupHandle handle;
    try {
      handle = await crypto.openCallGroup();
    } catch (_) {
      await keys.dispose();
      rethrow;
    }
    final parent = crypto.parentGroups;
    final engine = RoomEngine(
      api: api,
      crypto: handle.crypto,
      parent: parent,
      keys: keys,
      scheduler: scheduler,
      selfAccountId: selfAccountId,
      selfDeviceId: selfDeviceId,
    );
    final media =
        RoomMediaSession(engine: engine, keys: keys, sfu: connectSfu(keys))
          ..start();

    // Null (the L1 judgment not loaded yet) reads as its own roster, so the
    // engine refreshes once it loads.
    String rosterOf() =>
        (parent.members(conversationId)?.map((m) => m.id).toList() ?? ['?']
              ..sort())
            .join(',');
    var lastRoster = rosterOf();
    void onRoster() {
      final now = rosterOf();
      if (now == lastRoster) return;
      lastRoster = now;
      engine.refresh();
    }

    rosterChanges?.addListener(onRoster);
    RoomTimer? poll;
    void schedule() {
      poll = scheduler.after(pollEvery, () {
        engine.refresh();
        schedule();
      });
    }

    schedule();
    late final RoomCall call;
    var closing = false;
    Future<void> close() async {
      if (closing) return;
      closing = true;
      _open.remove(call);
      poll?.cancel();
      rosterChanges?.removeListener(onRoster);
      await media.close();
      await engine.leave();
      engine.dispose();
      await keys.dispose();
      handle.close();
    }

    call = RoomCall(engine: engine, controls: media, close: close);
    _open.add(call);
    return call;
  }

  /// Ends every open call (sign-out or account switch): no call outlives its
  /// session.
  Future<void> closeAll() async {
    _closed = true;
    for (final call in _open.toList()) {
      await call.close();
    }
  }
}
