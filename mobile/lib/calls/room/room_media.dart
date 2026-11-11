import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
///  - every subscribed track gets a receiver cryptor at once and stays
///    silent until it is bound. A track is bound to `account/device:slot`
///    only by a track announcement its sender sealed in the call group (an
///    MLS application message), never by the SFU's names; a track with no
///    binding keeps a cryptor with no key, so its frames are dropped and
///    never played in clear;
///  - announcements are sent again in every epoch, so newcomers learn them
///    and members that left cannot read them.

/// Stream slots (design, "Media keys").
const roomSlotVoice = 0;
const roomSlotCamera = 1;
const roomSlotScreen = 2;
const roomSlotScreenAudio = 3;

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
}

abstract interface class SfuRemoteTrack {
  String get sid;

  /// The SFU identity of the participant that publishes it: a pseudonym,
  /// used only to check an announcement against its sender's connection.
  String get participant;

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
  /// it. The capture must stay disabled until the caller enables it.
  Future<SfuLocalTrack> publishDisabled(int slot);
  Future<void> unpublish(SfuLocalTrack track);

  /// Frame cryptors keyed by [participantId] in [WebRtcFrameKeys.provider].
  Future<RoomFrameCryptor> senderCryptor(
      SfuLocalTrack track, String participantId);
  Future<RoomFrameCryptor> receiverCryptor(
      SfuRemoteTrack track, String participantId);

  /// Reliable data to every participant (here: sealed announcements only).
  Future<void> sendData(Uint8List data);
  Future<void> disconnect();
}

class _Sender {
  _Sender(this.track, this.cryptor);
  final SfuLocalTrack track;
  final RoomFrameCryptor cryptor;
}

class _Receiver {
  _Receiver(this.track, this.cryptor, this.boundTo);
  final SfuRemoteTrack track;
  RoomFrameCryptor cryptor;

  /// `account/device:slot`, or null while unbound (a cryptor with no key).
  String? boundTo;
}

class RoomMediaSession extends ChangeNotifier implements RoomMediaControls {
  RoomMediaSession({
    required this.engine,
    required this.keys,
    required this.sfu,
    this.publishVoice = true,
  });

  final RoomEngine engine;
  final WebRtcFrameKeys keys;
  final SfuConnection sfu;
  final bool publishVoice;

  /// Announcement payload version.
  static const announcementVersion = 1;

  bool _micMuted = false;
  bool _connecting = false;
  bool _connected = false;
  bool _closed = false;
  int? _announcedEpoch;
  Set<String> _roster = const {};
  _Sender? _voice;
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

  Future<void> _publish(int slot) async {
    final track = await sfu.publishDisabled(slot);
    final cryptor = await sfu.senderCryptor(track, '${engine.selfId}:$slot');
    if (!await cryptor.setEnabled(true)) {
      throw StateError('sender cryptor did not enable');
    }
    final sender = _Sender(track, cryptor);
    if (slot == roomSlotVoice) _voice = sender;
    await _applySendIndex(sender);
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

  void _onSendIndex() => unawaited(_serial(() async {
        final voice = _voice;
        if (voice != null) await _applySendIndex(voice);
      }));

  Future<void> _afterEngineChange() async {
    if (!_connected) return;
    final roster = {for (final m in engine.roster) m.id};
    final epoch = engine.epoch;
    final rosterChanged = !setEquals(roster, _roster);
    _roster = roster;
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
    final payload = utf8.encode(jsonEncode({
      'v': announcementVersion,
      'sfu': identity,
      'tracks': {
        if (_voice != null) _voice!.track.sid: _voice!.track.slot,
      },
    }));
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
        await receiver?.cryptor.dispose();
      case SfuData(:final participant, :final data):
        await _announcement(participant, data);
      case SfuDisconnected():
        await _failClosed();
    }
  }

  String _unbound(String sid) => 'unbound:$sid';

  Future<void> _subscribed(SfuRemoteTrack track) async {
    final RoomFrameCryptor cryptor;
    try {
      // A track that cannot be muted is never kept.
      await track.setPlaying(false);
      cryptor = await sfu.receiverCryptor(track, _unbound(track.sid));
      if (!await cryptor.setEnabled(true)) {
        await cryptor.dispose();
        throw StateError('receiver cryptor did not enable');
      }
    } catch (_) {
      // Never play a track that has no working cryptor.
      await track.unsubscribe();
      return;
    }
    final receiver = _Receiver(track, cryptor, null);
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

  /// Puts the cryptor [receiver] should have in place: bound to the member
  /// and slot its sender announced, or unbound (no key, frames dropped).
  Future<void> _rebind(_Receiver receiver) async {
    final binding = _bindings[receiver.track.sid];
    final target = binding != null &&
            binding.sfu == receiver.track.participant &&
            _roster.contains(binding.member) &&
            binding.member != engine.selfId
        ? '${binding.member}:${binding.slot}'
        : null;
    if (target == receiver.boundTo) return;
    // Silent while the cryptor is swapped, so no frame plays without one.
    await receiver.track.setPlaying(false);
    await receiver.cryptor.dispose();
    final cryptor = await sfu.receiverCryptor(
        receiver.track, target ?? _unbound(receiver.track.sid));
    receiver.cryptor = cryptor;
    receiver.boundTo = null;
    if (!await cryptor.setEnabled(true)) {
      _receivers.remove(receiver.track.sid);
      await cryptor.dispose();
      await receiver.track.unsubscribe();
      return;
    }
    receiver.boundTo = target;
    if (target != null) await receiver.track.setPlaying(true);
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
      final voice = _voice;
      if (voice != null) await _applySendIndex(voice);
    });
  }

  /// Screen share is not built yet (design, "Not built"): the platform
  /// capture pickers come with it.
  @override
  bool get canShareScreen => false;

  @override
  bool get sharingScreen => false;

  @override
  Future<void> setSharingScreen(bool on) async {}

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
    final voice = _voice;
    _voice = null;
    if (voice != null) {
      try {
        await voice.track.setEnabled(false);
        await voice.cryptor.dispose();
        await sfu.unpublish(voice.track);
      } catch (_) {}
    }
    for (final receiver in _receivers.values) {
      try {
        await receiver.track.setPlaying(false);
        await receiver.cryptor.dispose();
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
