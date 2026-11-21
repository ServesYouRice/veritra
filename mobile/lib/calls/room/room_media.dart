import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'room_capture.dart';
import 'room_engine.dart';
import 'room_ports.dart';
import 'webrtc_frame_keys.dart';

/// B6 media transport: the SFU connection, kept fail closed.
///
/// Rules (docs/designs/B6-group-calls.md, "Required cryptor settings"):
///  - every local track is published disabled (silence or black frames),
///    its frame cryptor is attached and enabled, the send key index is set,
///    and only then is the track enabled; a cryptor that cannot be enabled
///    ends the call;
///  - every subscribed track gets one receiver cryptor at once, keyed by
///    `rx:<track sid>` and kept until the track goes, and stays silent
///    until it is bound. A track is bound to `account/device:slot` only by
///    a track announcement its sender sealed in the call group (an MLS
///    application message), never by the SFU's names: binding copies that
///    member's slot keys into the track's alias ([WebRtcFrameKeys.bindAlias])
///    and unbinding overwrites them with random bytes, so the cryptor on the
///    RTP receiver is never disposed or recreated. A track with no binding
///    has no key, so its frames are dropped and never played in clear;
///  - announcements are sent again in every epoch, so newcomers learn them
///    and members that left cannot read them.

/// Stream slots (design, "Media keys").
const roomSlotVoice = 0;
const roomSlotCamera = 1;
const roomSlotScreen = 2;
const roomSlotScreenAudio = 3;

/// Camera and screen share work in rooms of at most this many devices; a
/// bigger room is voice only (O3).
const roomVideoCap = 25;

/// The capture could not be created (permission refused, no camera, the user
/// cancelled the picker). Nothing was published. Unlike a cryptor that will
/// not enable, it does not end the call.
class SfuCaptureDenied implements Exception {
  const SfuCaptureDenied();
  @override
  String toString() => 'SfuCaptureDenied';
}

/// A frame cryptor on one sender or receiver.
abstract interface class RoomFrameCryptor {
  Future<bool> setEnabled(bool enabled);
  Future<bool> setKeyIndex(int index);
  Future<void> dispose();
}

abstract interface class SfuLocalTrack {
  /// The SFU's id for the published track.
  String get sid;
  int get slot;

  /// Whether the capture reaches the encoder. Off sends silence or black.
  Future<void> setEnabled(bool enabled);

  /// Fires once when the capture ends by itself (the user stopped sharing
  /// from the system's own control, the window closed, the camera was
  /// unplugged).
  Stream<void> get ended;

  /// The capture's local stream for a preview tile (camera only), or null.
  /// An opaque handle for the tile builder.
  Object? get preview;
}

abstract interface class SfuRemoteTrack {
  String get sid;

  /// The SFU identity of the participant that publishes it: a pseudonym,
  /// used only to check an announcement against its sender's connection.
  String get participant;

  /// Whether the track carries video (a camera or a shared screen).
  bool get isVideo;

  /// The received stream, an opaque handle for the tile builder. Drawn only
  /// once the track is bound.
  Object? get stream;

  /// Whether received frames reach the speaker or the screen.
  Future<void> setPlaying(bool playing);
  Future<void> unsubscribe();
}

sealed class SfuEvent {
  const SfuEvent();
}

class SfuTrackSubscribed extends SfuEvent {
  const SfuTrackSubscribed(this.track);
  final SfuRemoteTrack track;
}

class SfuTrackUnsubscribed extends SfuEvent {
  const SfuTrackUnsubscribed(this.sid);
  final String sid;
}

class SfuData extends SfuEvent {
  const SfuData(this.participant, this.data);
  final String? participant;
  final Uint8List data;
}

class SfuDisconnected extends SfuEvent {
  const SfuDisconnected();
}

/// The SFU client. One per call.
abstract interface class SfuConnection {
  Future<void> connect(String url, String token);

  /// This device's SFU identity once connected.
  String? get localIdentity;
  Stream<SfuEvent> get events;

  /// Creates the capture for [slot] with its track disabled, then publishes
  /// it. The capture must stay disabled until the caller enables it. Throws
  /// [SfuCaptureDenied] when no capture could be created. [sourceId] picks
  /// the screen or window for [roomSlotScreen] on desktop.
  Future<SfuLocalTrack> publishDisabled(int slot, {String? sourceId});
  Future<void> unpublish(SfuLocalTrack track);

  /// Frame cryptors keyed by [participantId] in [WebRtcFrameKeys.provider].
  Future<RoomFrameCryptor> senderCryptor(
    SfuLocalTrack track,
    String participantId,
  );
  Future<RoomFrameCryptor> receiverCryptor(
    SfuRemoteTrack track,
    String participantId,
  );

  /// Reliable data to every participant (here: sealed announcements only).
  Future<void> sendData(Uint8List data);
  Future<void> disconnect();
}

class _Sender {
  _Sender(this.track, this.cryptor);
  final SfuLocalTrack track;
  final RoomFrameCryptor cryptor;
  StreamSubscription<void>? endedSub;
}

class _Receiver {
  _Receiver(this.track, this.cryptor);
  final SfuRemoteTrack track;

  /// Keyed by [RoomMediaSession.receiverKeyId] for the track's whole life.
  final RoomFrameCryptor cryptor;

  /// `account/device:slot`, or null while unbound (no key).
  String? boundTo;
}

class RoomMediaSession extends ChangeNotifier implements RoomMediaControls {
  RoomMediaSession({
    required this.engine,
    required this.keys,
    required this.sfu,
    this.publishVoice = true,
    this.capture = const NoRoomCapture(),
    this.videoCap = roomVideoCap,
  });

  final RoomEngine engine;
  final WebRtcFrameKeys keys;
  final SfuConnection sfu;
  final bool publishVoice;

  /// What this platform can capture and the consent steps before it.
  final RoomCapture capture;

  /// Camera and screen share are refused in a room with more devices than
  /// this, and stop if the room grows past it (O3).
  final int videoCap;

  /// Announcement payload version.
  static const announcementVersion = 1;

  bool _micMuted = false;
  bool _connecting = false;
  bool _connected = false;
  bool _closed = false;
  int? _announcedEpoch;
  Set<String> _roster = const {};
  final Map<int, _Sender> _senders = {};

  /// Capture creations in flight: the OS may be asking for permission.
  int _capturing = 0;

  /// OS consent steps in flight (screen capture permission).
  int _preparing = 0;

  /// Slots whose capture is being started, before they are registered.
  final Set<int> _videoStarting = {};

  /// Starting slots the person switched off again before they were
  /// registered: the capture is released, never enabled.
  final Set<int> _cancelStart = {};
  RoomMediaNotice? _notice;
  StreamSubscription<SfuEvent>? _events;
  final Map<String, _Receiver> _receivers = {};

  /// Members whose announcement this device opened in the current epoch.
  final Set<String> _heard = {};

  /// Track sid -> (sender SFU identity, `account/device`, slot), from sealed
  /// announcements of the current epoch.
  final Map<String, ({String sfu, String member, int slot})> _bindings = {};
  Future<void> _tail = Future<void>.value();

  /// Bound remote tracks, for the UI and tests: sid -> `account/device:slot`.
  Map<String, String> get boundTracks => {
        for (final entry in _receivers.entries)
          if (entry.value.boundTo != null) entry.key: entry.value.boundTo!,
      };

  void start() {
    engine.addListener(_onEngine);
    keys.sendIndex.addListener(_onSendIndex);
    keys.failed.addListener(_onKeysFailed);
    _events = sfu.events.listen((event) {
      _serial(() => _onEvent(event));
    });
    _onEngine();
  }

  Future<void> _serial(Future<void> Function() step) {
    return _tail = _tail.then((_) async {
      if (_closed) return;
      try {
        await step();
      } catch (_) {
        await _failClosed();
      }
    });
  }

  /// Completes when the queued media work is done (tests).
  Future<void> get idle => _tail;

  void _onEngine() {
    if (_closed) return;
    final phase = engine.phase;
    if (phase == RoomPhase.left || phase == RoomPhase.failed) {
      unawaited(close());
      return;
    }
    if (phase != RoomPhase.active) return;
    if (!_connected && !_connecting) {
      _connecting = true;
      unawaited(_serial(_connect));
    }
    unawaited(_serial(_afterEngineChange));
  }

  void _onKeysFailed() {
    if (keys.failed.value) unawaited(_serial(_failClosed));
  }

  Future<void> _connect() async {
    final url = engine.sfuUrl;
    final token = engine.sfuToken;
    if (url == null || token == null) throw StateError('no SFU token');
    await sfu.connect(url, token);
    _connected = true;
    if (publishVoice) await _publish(roomSlotVoice);
    await _announce(force: true);
  }

  /// Voice at connect: capture, then register, in one serial step.
  Future<void> _publish(int slot) async {
    final track = await _capture(slot, null);
    if (track != null) await _register(slot, track);
  }

  /// Attaches the sender cryptor to a published (still disabled) [track],
  /// then sets its key index and only then lets it through. A cryptor that
  /// will not enable ends the call ([_serial]).
  Future<void> _register(int slot, SfuLocalTrack track) async {
    final _Sender sender;
    try {
      final cryptor = await sfu.senderCryptor(track, '${engine.selfId}:$slot');
      if (!await cryptor.setEnabled(true)) {
        await cryptor.dispose();
        throw StateError('sender cryptor did not enable');
      }
      sender = _Sender(track, cryptor);
    } catch (_) {
      // Published without a working cryptor: stays disabled; the call ends.
      await track.setEnabled(false);
      rethrow;
    }
    _senders[slot] = sender;
    if (slot != roomSlotVoice) {
      sender.endedSub = track.ended.listen(
        (_) => unawaited(_serial(() => _stopVideo(slot))),
      );
    }
    await _applySendIndex(sender);
    if (slot != roomSlotVoice) {
      await _announce(force: true);
      notifyListeners();
    }
  }

  /// Creates and publishes the (disabled) capture for [slot], counting it as
  /// a permission request while the OS may be asking. Null when the capture
  /// was refused: the notice says why and the call goes on.
  Future<SfuLocalTrack?> _capture(int slot, String? sourceId) async {
    _capturing++;
    notifyListeners();
    try {
      return await sfu.publishDisabled(slot, sourceId: sourceId);
    } on SfuCaptureDenied {
      if (slot == roomSlotCamera) {
        _setNotice(RoomMediaNotice.cameraUnavailable);
      } else if (slot == roomSlotScreen) {
        _setNotice(RoomMediaNotice.screenUnavailable);
      }
      return null;
    } finally {
      _capturing--;
      notifyListeners();
    }
  }

  /// Sets the sender's key index, waiting for the keys before it, and only
  /// then lets the capture through (unless muted).
  Future<void> _applySendIndex(_Sender sender) async {
    await keys.idle;
    final index = keys.sendIndex.value;
    if (index == null) {
      await sender.track.setEnabled(false);
      return;
    }
    if (!await sender.cryptor.setKeyIndex(index)) {
      throw StateError('sender key index refused');
    }
    final on = sender.track.slot != roomSlotVoice || !_micMuted;
    await sender.track.setEnabled(on);
  }

  /// Every sender moves to the new epoch's key: a track left on the old
  /// index would go dark when the receivers drop that key.
  void _onSendIndex() => unawaited(
        _serial(() async {
          for (final sender in _senders.values.toList()) {
            await _applySendIndex(sender);
          }
        }),
      );

  Future<void> _afterEngineChange() async {
    if (!_connected) return;
    final roster = {for (final m in engine.roster) m.id};
    final epoch = engine.epoch;
    final rosterChanged = !setEquals(roster, _roster);
    _roster = roster;
    if (roster.length > videoCap) await _stopAllVideo();
    if (epoch != _announcedEpoch) {
      _heard.clear();
      // Bindings came in sealed for an earlier epoch; senders repeat them.
      // Bindings of members still in the call stay until they do, so their
      // tracks keep playing; a member who left loses them at once.
      _bindings.removeWhere((_, b) => !roster.contains(b.member));
      await _announce();
    }
    if (rosterChanged) {
      for (final receiver in _receivers.values.toList()) {
        await _rebind(receiver);
      }
    }
  }

  Future<void> _announce({bool force = false}) async {
    final epoch = engine.epoch;
    if (epoch == null) return;
    if (!force && epoch == _announcedEpoch) return;
    final identity = sfu.localIdentity;
    if (identity == null) return;
    final payload = utf8.encode(
      jsonEncode({
        'v': announcementVersion,
        'sfu': identity,
        'tracks': {
          for (final sender in _senders.values)
            sender.track.sid: sender.track.slot,
        },
      }),
    );
    final sealed = await engine.sealSignal(Uint8List.fromList(payload));
    if (sealed == null) return;
    _announcedEpoch = epoch;
    await sfu.sendData(sealed);
  }

  Future<void> _onEvent(SfuEvent event) async {
    switch (event) {
      case SfuTrackSubscribed(:final track):
        await _subscribed(track);
      case SfuTrackUnsubscribed(:final sid):
        final receiver = _receivers.remove(sid);
        if (receiver != null) {
          keys.unbindAlias(receiverKeyId(sid));
          await receiver.cryptor.dispose();
          notifyListeners();
        }
      case SfuData(:final participant, :final data):
        await _announcement(participant, data);
      case SfuDisconnected():
        await _failClosed();
    }
  }

  /// The key provider id of a remote track's receiver cryptor: an alias
  /// that mirrors the bound member's slot keys, and holds none unbound.
  static String receiverKeyId(String sid) => 'rx:$sid';

  Future<void> _subscribed(SfuRemoteTrack track) async {
    final RoomFrameCryptor cryptor;
    try {
      // A track that cannot be muted is never kept.
      await track.setPlaying(false);
      // A track the SFU subscribes again under the same sid keeps no key
      // from before.
      keys.unbindAlias(receiverKeyId(track.sid));
      await _receivers.remove(track.sid)?.cryptor.dispose();
      cryptor = await sfu.receiverCryptor(track, receiverKeyId(track.sid));
      if (!await cryptor.setEnabled(true)) {
        await cryptor.dispose();
        throw StateError('receiver cryptor did not enable');
      }
    } catch (_) {
      // Never play a track that has no working cryptor.
      await track.unsubscribe();
      return;
    }
    final receiver = _Receiver(track, cryptor);
    _receivers[track.sid] = receiver;
    await _rebind(receiver);
  }

  Future<void> _announcement(String? participant, Uint8List data) async {
    if (participant == null) return; // the SFU's own data is never trusted
    final opened = await engine.openSignal(data);
    if (opened == null) return;
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(opened.plaintext));
    } catch (_) {
      return;
    }
    if (json is! Map ||
        json['v'] != announcementVersion ||
        json['sfu'] != participant ||
        json['tracks'] is! Map) {
      return;
    }
    final member = opened.sender.id;
    // A member heard from for the first time in this epoch may have missed
    // ours (it was still joining when we sent it): answer once.
    if (_heard.add(member)) await _announce(force: true);
    // The sender's announcement replaces its earlier one.
    _bindings.removeWhere((_, b) => b.member == member);
    (json['tracks'] as Map).forEach((sid, slot) {
      if (sid is String &&
          slot is int &&
          slot >= 0 &&
          slot < RoomEngine.streamSlots) {
        _bindings[sid] = (sfu: participant, member: member, slot: slot);
      }
    });
    for (final receiver in _receivers.values.toList()) {
      await _rebind(receiver);
    }
  }

  /// Puts the keys [receiver]'s cryptor should have in place: the member and
  /// slot its sender announced, or none (frames dropped). The cryptor stays.
  Future<void> _rebind(_Receiver receiver) async {
    final binding = _bindings[receiver.track.sid];
    final target = binding != null &&
            binding.sfu == receiver.track.participant &&
            _roster.contains(binding.member) &&
            binding.member != engine.selfId
        ? '${binding.member}:${binding.slot}'
        : null;
    if (target == receiver.boundTo) return;
    // Silent while the keys change, so nothing plays under the wrong ones.
    await receiver.track.setPlaying(false);
    receiver.boundTo = null;
    final alias = receiverKeyId(receiver.track.sid);
    if (target == null) {
      keys.unbindAlias(alias);
      await keys.idle;
      notifyListeners();
      return;
    }
    keys.bindAlias(alias, target);
    await keys.idle;
    // A key the provider refused ends the call ([_onKeysFailed]).
    if (keys.failed.value || _receivers[receiver.track.sid] != receiver) {
      return;
    }
    receiver.boundTo = target;
    await receiver.track.setPlaying(true);
    notifyListeners();
  }

  // ---- controls -----------------------------------------------------------

  @override
  bool get micMuted => _micMuted;

  @override
  Future<void> setMicMuted(bool muted) async {
    _micMuted = muted;
    notifyListeners();
    await _serial(() async {
      final voice = _senders[roomSlotVoice];
      if (voice != null) await _applySendIndex(voice);
    });
  }

  @override
  bool get requestingPermission => _capturing > 0 || _preparing > 0;

  @override
  RoomMediaNotice? get notice => _notice;

  @override
  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  void _setNotice(RoomMediaNotice notice) {
    _notice = notice;
    notifyListeners();
  }

  /// Video needs a room of at most [videoCap] devices (O3).
  bool get _videoRoomOk => engine.roster.length <= videoCap;

  @override
  bool get canUseCamera => _connected && !_closed && capture.canUseCamera;

  bool _isOn(int slot) =>
      _senders.containsKey(slot) ||
      _videoStarting.contains(slot) && !_cancelStart.contains(slot);

  /// A start in flight is cancelled by switching off, and kept by switching
  /// on again. Returns true when [slot] was starting.
  bool _retarget(int slot, {required bool on}) {
    if (!_videoStarting.contains(slot)) return false;
    if (on) {
      _cancelStart.remove(slot);
    } else {
      _cancelStart.add(slot);
    }
    notifyListeners();
    return true;
  }

  @override
  bool get cameraOn => _isOn(roomSlotCamera);

  @override
  Future<void> setCameraOn(bool on) async {
    if (!on) {
      _retarget(roomSlotCamera, on: false);
      await _serial(() => _stopVideo(roomSlotCamera));
      return;
    }
    if (_retarget(roomSlotCamera, on: true)) return;
    if (!canUseCamera || cameraOn) return;
    _notice = null;
    if (!_videoRoomOk) {
      _setNotice(RoomMediaNotice.videoRoomFull);
      return;
    }
    await _startVideo(roomSlotCamera);
  }

  @override
  bool get canShareScreen => _connected && !_closed && capture.canShareScreen;

  @override
  bool get sharingScreen => _isOn(roomSlotScreen);

  @override
  bool get screenNeedsSource => capture.screenNeedsSource;

  @override
  Future<List<ScreenSource>> screenSources() => capture.screenSources();

  @override
  Future<void> setSharingScreen(bool on, {String? sourceId}) async {
    if (!on) {
      _retarget(roomSlotScreen, on: false);
      await _serial(() => _stopVideo(roomSlotScreen));
      return;
    }
    if (_retarget(roomSlotScreen, on: true)) return;
    if (!canShareScreen || sharingScreen) return;
    _notice = null;
    if (!_videoRoomOk) {
      _setNotice(RoomMediaNotice.videoRoomFull);
      return;
    }
    if (capture.screenNeedsSource && (sourceId == null || sourceId.isEmpty)) {
      _setNotice(RoomMediaNotice.screenNoSource);
      return;
    }
    await _startVideo(roomSlotScreen, sourceId: sourceId);
  }

  /// Starts the camera or the screen share. The platform consent and the
  /// capture creation run outside the serial queue: the OS may wait on the
  /// person for a long time, and key switches and announcements must not wait
  /// behind it. Registering the track (its cryptor, key index and announce)
  /// is queued like every other media step.
  Future<void> _startVideo(int slot, {String? sourceId}) async {
    _videoStarting.add(slot);
    notifyListeners();
    SfuLocalTrack? track;
    try {
      if (slot == roomSlotScreen) {
        _preparing++;
        notifyListeners();
        final bool ready;
        try {
          ready = await capture.beginScreenShare();
        } finally {
          _preparing--;
        }
        if (!ready) {
          _setNotice(RoomMediaNotice.screenUnavailable);
          return;
        }
      }
      if (_closed || _cancelStart.contains(slot)) return;
      track = await _capture(slot, sourceId);
      if (track == null) return;
      if (_closed || _cancelStart.contains(slot)) {
        // The call ended, or the person switched it off again, while the OS
        // was asking: nothing may stay open, and nothing is enabled.
        await _release(track);
        track = null;
        return;
      }
      final published = track;
      track = null;
      await _serial(() async {
        if (_cancelStart.contains(slot)) {
          await _release(published);
          return;
        }
        await _register(slot, published);
      });
      // The call ended while this step waited its turn (it was skipped).
      if (_closed) await _release(published);
    } catch (_) {
      // An unexpected failure in the platform step: not a cryptor refusal,
      // so only this video stops. A failure after the track was published
      // is handled by [_serial] (the call ends).
      if (track != null) await _release(track);
      _setNotice(
        slot == roomSlotCamera
            ? RoomMediaNotice.cameraUnavailable
            : RoomMediaNotice.screenUnavailable,
      );
    } finally {
      _videoStarting.remove(slot);
      _cancelStart.remove(slot);
      if (slot == roomSlotScreen && !_senders.containsKey(slot)) {
        await capture.endScreenShare();
      }
      notifyListeners();
    }
  }

  Future<void> _release(SfuLocalTrack track) async {
    try {
      await track.setEnabled(false);
    } catch (_) {}
    try {
      await sfu.unpublish(track);
    } catch (_) {}
  }

  /// Takes a registered sender down, each step on its own so that one that
  /// fails does not leave the capture running: disabled, unpublished (which
  /// stops the capture), and only then is its cryptor removed, so the
  /// sender never carries a live capture without it.
  Future<void> _teardown(_Sender sender) async {
    await sender.endedSub?.cancel();
    await _release(sender.track);
    try {
      await sender.cryptor.dispose();
    } catch (_) {}
  }

  /// Stops one video: the capture, its cryptor and its publication, so the
  /// camera light goes out, then tells the room.
  Future<void> _stopVideo(int slot) async {
    final sender = _senders.remove(slot);
    if (sender == null) return;
    await _teardown(sender);
    if (slot == roomSlotScreen) await capture.endScreenShare();
    if (_connected && !_closed) await _announce(force: true);
    notifyListeners();
  }

  Future<void> _stopAllVideo() async {
    final had = _senders.keys.any((s) => s != roomSlotVoice);
    await _stopVideo(roomSlotCamera);
    await _stopVideo(roomSlotScreen);
    if (had) _setNotice(RoomMediaNotice.videoRoomFull);
  }

  @override
  List<RoomVideoTile> get videoTiles {
    final tiles = <RoomVideoTile>[];
    final preview = _senders[roomSlotCamera]?.track.preview;
    if (preview != null) {
      tiles.add(
        RoomVideoTile(
            id: 'local-camera', slot: roomSlotCamera, stream: preview),
      );
    }
    for (final entry in _receivers.entries) {
      final bound = entry.value.boundTo;
      final stream = entry.value.track.stream;
      if (bound == null || stream == null || !entry.value.track.isVideo) {
        continue;
      }
      final colon = bound.lastIndexOf(':');
      final slot = int.tryParse(bound.substring(colon + 1));
      if (slot != roomSlotCamera && slot != roomSlotScreen) continue;
      tiles.add(
        RoomVideoTile(
          id: entry.key,
          memberId: bound.substring(0, colon),
          slot: slot!,
          stream: stream,
        ),
      );
    }
    return tiles;
  }

  // ---- ending -------------------------------------------------------------

  Future<void> _failClosed() async {
    if (_closed) return;
    await close();
    await engine.failClosed();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    engine.removeListener(_onEngine);
    keys.sendIndex.removeListener(_onSendIndex);
    keys.failed.removeListener(_onKeysFailed);
    await _events?.cancel();
    final hadScreen = _senders.containsKey(roomSlotScreen) ||
        _videoStarting.contains(roomSlotScreen);
    final senders = _senders.values.toList();
    _senders.clear();
    for (final sender in senders) {
      await _teardown(sender);
    }
    if (hadScreen) await capture.endScreenShare();
    for (final entry in _receivers.entries) {
      try {
        await entry.value.track.setPlaying(false);
        keys.unbindAlias(receiverKeyId(entry.key));
        await entry.value.cryptor.dispose();
      } catch (_) {}
    }
    _receivers.clear();
    _bindings.clear();
    try {
      await sfu.disconnect();
    } catch (_) {}
    notifyListeners();
  }
}
