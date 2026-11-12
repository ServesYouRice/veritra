import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'room_media.dart';
import 'webrtc_frame_keys.dart';

/// [SfuConnection] on a LiveKit server (O1, D106) through `livekit_client`.
///
/// LiveKit's own end-to-end encryption manager is not used: it keys frames
/// by the SFU's participant names and one key per participant. B6 attaches
/// libwebrtc frame cryptors itself, keyed per `account/device:slot` from
/// the MLS-derived keys in [WebRtcFrameKeys], and binds tracks by sealed
/// announcements ([RoomMediaSession]). The room therefore runs without
/// `e2eeOptions`, and voice is published with DTX and RED off (O4).
///
/// Fail closed around LiveKit's own steps (review HIGH and MEDIUM, round 7):
///  - a full reconnect (`RoomReconnectingEvent`) builds a new peer
///    connection and publishes the local tracks again on new RTP senders
///    with no frame cryptor. Inside the event's own callback, before any
///    later LiveKit step, every local track is disabled, the connection is
///    poisoned (no track is enabled or published on it again) and the
///    session is told the SFU is gone, so the call ends;
///  - any `LocalTrackPublishedEvent` for a sender that carries no cryptor
///    this connection attached (a republish the reconnect event did not
///    announce) does the same; only this connection's own publish, while
///    its track is still disabled and waiting for its cryptor, passes;
///  - a subscribed track is disabled in the event's callback, then LiveKit
///    starts it, which enables it again (`RemoteTrack.start`). The track is
///    handed to the session only after that start has run and the track has
///    been disabled again ("re-mute after start"; LiveKit's internal
///    `EngineTrackAddedEvent` is not part of its public API). A track that
///    never starts is unsubscribed.
class LiveKitSfuConnection implements SfuConnection {
  LiveKitSfuConnection(WebRtcFrameKeys keys,
      {LiveKitRoomDriver? driver,
      this.remoteStartWait = const Duration(seconds: 10)})
      : _driver = driver ?? _LkRoomDriver(keys);

  final LiveKitRoomDriver _driver;

  /// How long a subscribed track may take to start before it is dropped.
  final Duration remoteStartWait;

  final StreamController<SfuEvent> _events =
      StreamController<SfuEvent>.broadcast();
  final List<_LiveKitLocalTrack> _local = [];

  /// The RTP senders this connection attached a frame cryptor to, compared
  /// by identity.
  final List<Object> _keyedSenders = [];

  /// Tracks published by [publishDisabled] that wait for their cryptor.
  final Set<String> _awaitingCryptor = {};
  int _publishing = 0;
  bool _poisoned = false;
  final Map<String, _LiveKitRemoteTrack> _starting = {};

  /// Whether the connection reconnected or saw a track it did not key: no
  /// track is enabled or published on it again.
  bool get poisoned => _poisoned;

  @override
  String? get localIdentity => _driver.localIdentity;

  @override
  Stream<SfuEvent> get events => _events.stream;

  void _emit(SfuEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> connect(String url, String token) =>
      _driver.connect(url, token, _onRoomEvent);

  /// Runs inside LiveKit's listener callback: nothing here awaits before
  /// the tracks are disabled.
  void _onRoomEvent(LiveKitRoomEvent event) {
    switch (event) {
      case LiveKitReconnecting() || LiveKitDisconnected():
        _failClosedNow();
      case LiveKitLocalTrackPublished(:final sid, :final media):
        final sender = media?.sender;
        final keyed =
            sender != null && _keyedSenders.any((s) => identical(s, sender));
        final ownPublish = media != null &&
            !media.enabled &&
            (_publishing > 0 || _awaitingCryptor.contains(sid));
        if (_poisoned || !(keyed || ownPublish)) {
          if (media != null) _disable(media);
          _failClosedNow();
        }
      case LiveKitTrackSubscribed(:final track):
        _subscribed(track);
      case LiveKitTrackUnsubscribed(:final sid):
        _starting.remove(sid);
        _emit(SfuTrackUnsubscribed(sid));
      case LiveKitDataReceived(:final participant, :final data):
        _emit(SfuData(participant, data));
    }
  }

  void _failClosedNow() {
    for (final track in _local) {
      _disable(track.media);
    }
    _poisoned = true;
    _emit(const SfuDisconnected());
  }

  static void _disable(LiveKitMedia media) {
    try {
      media.enabled = false;
    } catch (_) {}
  }

  void _subscribed(LiveKitRemoteMedia media) {
    // Muted here, synchronously: nothing plays until the session binds the
    // track through MLS.
    try {
      _setEnabled(media, false);
    } catch (_) {
      unawaited(media.unsubscribe());
      return;
    }
    final track = _LiveKitRemoteTrack(media);
    _starting[media.sid] = track;
    unawaited(_afterStart(track));
  }

  /// Waits until LiveKit has started [track] (its start enables it), then
  /// disables it again and only then hands it to the session.
  Future<void> _afterStart(_LiveKitRemoteTrack track) async {
    final media = track.media;
    final waited = Stopwatch()..start();
    while (!media.isActive) {
      if (waited.elapsed > remoteStartWait || _starting[media.sid] != track) {
        if (_starting[media.sid] == track) {
          _starting.remove(media.sid);
          unawaited(media.unsubscribe());
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // The enable after the start runs in the microtasks that follow it.
    await Future<void>.delayed(Duration.zero);
    if (_starting[media.sid] != track) return;
    _starting.remove(media.sid);
    try {
      _setEnabled(media, track.playing);
    } catch (_) {
      unawaited(media.unsubscribe());
      return;
    }
    _emit(SfuTrackSubscribed(track));
  }

  @override
  Future<SfuLocalTrack> publishDisabled(int slot) async {
    if (slot != roomSlotVoice) {
      throw UnsupportedError('only voice is published (camera and screen '
          'share are not built)');
    }
    if (_poisoned) throw StateError('the SFU connection is not fail closed');
    final LiveKitLocalMedia media;
    _publishing++;
    try {
      media = await _driver.publishVoiceDisabled();
      _awaitingCryptor.add(media.sid);
    } finally {
      _publishing--;
    }
    final track = _LiveKitLocalTrack(this, media, slot);
    _local.add(track);
    if (_poisoned || media.enabled) {
      _disable(media);
      throw StateError('the SFU connection is not fail closed');
    }
    return track;
  }

  @override
  Future<void> unpublish(SfuLocalTrack track) async {
    final local = track as _LiveKitLocalTrack;
    _disable(local.media);
    _local.remove(local);
    _awaitingCryptor.remove(local.sid);
    await _driver.unpublish(local.sid);
  }

  @override
  Future<RoomFrameCryptor> senderCryptor(
      SfuLocalTrack track, String participantId) async {
    final local = track as _LiveKitLocalTrack;
    final sender = local.media.sender;
    if (sender == null) throw StateError('track has no sender');
    if (_poisoned) throw StateError('the SFU connection is not fail closed');
    final cryptor = await _driver.senderCryptor(sender, participantId);
    if (_poisoned || !identical(local.media.sender, sender)) {
      await cryptor.dispose();
      throw StateError('the track changed sender while its cryptor was made');
    }
    _keyedSenders.add(sender);
    _awaitingCryptor.remove(local.sid);
    return cryptor;
  }

  @override
  Future<RoomFrameCryptor> receiverCryptor(
      SfuRemoteTrack track, String participantId) async {
    final receiver = (track as _LiveKitRemoteTrack).media.receiver;
    if (receiver == null) throw StateError('track has no receiver');
    return _driver.receiverCryptor(receiver, participantId);
  }

  @override
  Future<void> sendData(Uint8List data) => _driver.publishData(data);

  @override
  Future<void> disconnect() async {
    for (final track in _local) {
      _disable(track.media);
    }
    _starting.clear();
    try {
      await _driver.disconnect();
    } finally {
      await _events.close();
    }
  }
}

// ---- the LiveKit room, behind a seam ---------------------------------------

/// The media track under a LiveKit track.
abstract interface class LiveKitMedia {
  /// The media track's enabled flag: off sends or plays silence.
  bool get enabled;
  set enabled(bool on);
}

abstract interface class LiveKitLocalMedia implements LiveKitMedia {
  String get sid;

  /// The RTP sender carrying it now (a full reconnect replaces it).
  Object? get sender;
}

abstract interface class LiveKitRemoteMedia implements LiveKitMedia {
  String get sid;

  /// The SFU identity of the participant that publishes it.
  String get participant;

  /// Whether LiveKit has started it (its start enables it).
  bool get isActive;
  Object? get receiver;
  Future<void> unsubscribe();
}

sealed class LiveKitRoomEvent {
  const LiveKitRoomEvent();
}

class LiveKitReconnecting extends LiveKitRoomEvent {
  const LiveKitReconnecting();
}

class LiveKitDisconnected extends LiveKitRoomEvent {
  const LiveKitDisconnected();
}

class LiveKitLocalTrackPublished extends LiveKitRoomEvent {
  const LiveKitLocalTrackPublished(this.sid, this.media);
  final String sid;
  final LiveKitLocalMedia? media;
}

class LiveKitTrackSubscribed extends LiveKitRoomEvent {
  const LiveKitTrackSubscribed(this.track);
  final LiveKitRemoteMedia track;
}

class LiveKitTrackUnsubscribed extends LiveKitRoomEvent {
  const LiveKitTrackUnsubscribed(this.sid);
  final String sid;
}

class LiveKitDataReceived extends LiveKitRoomEvent {
  const LiveKitDataReceived(this.participant, this.data);
  final String? participant;
  final Uint8List data;
}

/// The LiveKit room as [LiveKitSfuConnection] uses it. The default wraps
/// `livekit_client`'s Room; tests drive a fake. [connect]'s handler is
/// called synchronously from inside LiveKit's own listener callbacks.
abstract interface class LiveKitRoomDriver {
  String? get localIdentity;
  Future<void> connect(
      String url, String token, void Function(LiveKitRoomEvent) onEvent);

  /// Creates the voice capture, starts and disables it, then publishes it.
  Future<LiveKitLocalMedia> publishVoiceDisabled();
  Future<void> unpublish(String sid);
  Future<void> publishData(Uint8List data);
  Future<void> disconnect();
  Future<RoomFrameCryptor> senderCryptor(Object sender, String participantId);
  Future<RoomFrameCryptor> receiverCryptor(
      Object receiver, String participantId);
}

class _LkRoomDriver implements LiveKitRoomDriver {
  _LkRoomDriver(this.keys);

  final WebRtcFrameKeys keys;
  final lk.Room _room = lk.Room(
    roomOptions: const lk.RoomOptions(
      adaptiveStream: false,
      dynacast: false,
      defaultAudioPublishOptions: _voiceOptions,
    ),
  );
  lk.EventsListener<lk.RoomEvent>? _listener;

  /// Constant 32 kbit/s voice, DTX and RED off (O4). libwebrtc may still
  /// vary the Opus packet size, and the audio-level header extension cannot
  /// be turned off through `livekit_client` (design risk, S1 checks).
  static const _voiceOptions = lk.AudioPublishOptions(
    dtx: false,
    red: false,
    encoding: lk.AudioEncoding(maxBitrate: 32000),
  );

  @override
  String? get localIdentity => _room.localParticipant?.identity;

  @override
  Future<void> connect(
      String url, String token, void Function(LiveKitRoomEvent) onEvent) async {
    final listener = _listener = _room.createListener();
    listener
      ..on<lk.RoomReconnectingEvent>(
          (_) => onEvent(const LiveKitReconnecting()))
      ..on<lk.RoomDisconnectedEvent>(
          (_) => onEvent(const LiveKitDisconnected()))
      ..on<lk.LocalTrackPublishedEvent>((event) {
        final track = event.publication.track;
        onEvent(LiveKitLocalTrackPublished(
            event.publication.sid,
            track == null
                ? null
                : _LkLocalMedia(track, event.publication.sid)));
      })
      ..on<lk.TrackSubscribedEvent>((event) => onEvent(LiveKitTrackSubscribed(
          _LkRemoteMedia(event.participant, event.publication, event.track))))
      ..on<lk.TrackUnsubscribedEvent>(
          (event) => onEvent(LiveKitTrackUnsubscribed(event.publication.sid)))
      ..on<lk.DataReceivedEvent>((event) => onEvent(LiveKitDataReceived(
          event.participant?.identity, Uint8List.fromList(event.data))));
    await _room.connect(url, token,
        connectOptions: const lk.ConnectOptions(autoSubscribe: true));
  }

  @override
  Future<LiveKitLocalMedia> publishVoiceDisabled() async {
    final participant = _room.localParticipant;
    if (participant == null) throw StateError('not connected');
    final track =
        await lk.LocalAudioTrack.create(const lk.AudioCaptureOptions());
    // Started and disabled before it is published: until its cryptor holds
    // a key the encoder sees silence only (publishing does not re-enable a
    // started track).
    await track.start();
    _setEnabled(_LkLocalMedia(track, ''), false);
    final publication = await participant.publishAudioTrack(track,
        publishOptions: _voiceOptions);
    return _LkLocalMedia(track, publication.sid);
  }

  @override
  Future<void> unpublish(String sid) async {
    await _room.localParticipant?.removePublishedTrack(sid);
  }

  @override
  Future<void> publishData(Uint8List data) async {
    await _room.localParticipant?.publishData(data, reliable: true);
  }

  @override
  Future<RoomFrameCryptor> senderCryptor(
          Object sender, String participantId) async =>
      _Cryptor(await rtc.frameCryptorFactory.createFrameCryptorForRtpSender(
        participantId: participantId,
        sender: sender as rtc.RTCRtpSender,
        algorithm: rtc.Algorithm.kAesGcm,
        keyProvider: keys.provider,
      ));

  @override
  Future<RoomFrameCryptor> receiverCryptor(
          Object receiver, String participantId) async =>
      _Cryptor(await rtc.frameCryptorFactory.createFrameCryptorForRtpReceiver(
        participantId: participantId,
        receiver: receiver as rtc.RTCRtpReceiver,
        algorithm: rtc.Algorithm.kAesGcm,
        keyProvider: keys.provider,
      ));

  @override
  Future<void> disconnect() async {
    await _listener?.dispose();
    _listener = null;
    await _room.disconnect();
    await _room.dispose();
  }
}

class _LkLocalMedia implements LiveKitLocalMedia {
  _LkLocalMedia(this.track, this.sid);
  final lk.Track track;
  @override
  final String sid;

  @override
  bool get enabled => track.mediaStreamTrack.enabled;
  @override
  set enabled(bool on) => track.mediaStreamTrack.enabled = on;

  @override
  Object? get sender => track.sender;
}

class _LkRemoteMedia implements LiveKitRemoteMedia {
  _LkRemoteMedia(this._participant, this._publication, this.track);
  final lk.RemoteParticipant _participant;
  final lk.RemoteTrackPublication _publication;
  final lk.Track track;

  @override
  String get sid => _publication.sid;

  @override
  String get participant => _participant.identity;

  @override
  bool get enabled => track.mediaStreamTrack.enabled;
  @override
  set enabled(bool on) => track.mediaStreamTrack.enabled = on;

  @override
  bool get isActive => track.isActive;

  @override
  Object? get receiver => track.receiver;

  @override
  Future<void> unsubscribe() => _publication.unsubscribe();
}

class _Cryptor implements RoomFrameCryptor {
  _Cryptor(this._cryptor);
  final rtc.FrameCryptor _cryptor;

  @override
  Future<bool> setEnabled(bool enabled) => _cryptor.setEnabled(enabled);

  @override
  Future<bool> setKeyIndex(int index) => _cryptor.setKeyIndex(index);

  @override
  Future<void> dispose() async {
    try {
      await _cryptor.setEnabled(false);
    } catch (_) {}
    await _cryptor.dispose();
  }
}

class _LiveKitLocalTrack implements SfuLocalTrack {
  _LiveKitLocalTrack(this._connection, this.media, this.slot);
  final LiveKitSfuConnection _connection;
  final LiveKitLocalMedia media;
  @override
  String get sid => media.sid;
  @override
  final int slot;

  @override
  Future<void> setEnabled(bool enabled) async {
    if (enabled && _connection._poisoned) {
      _setEnabled(media, false);
      throw StateError('the SFU connection is not fail closed');
    }
    _setEnabled(media, enabled);
  }
}

class _LiveKitRemoteTrack implements SfuRemoteTrack {
  _LiveKitRemoteTrack(this.media);
  final LiveKitRemoteMedia media;

  /// What the session asked for; applied again after LiveKit's start.
  bool playing = false;

  @override
  String get sid => media.sid;

  @override
  String get participant => media.participant;

  @override
  Future<void> setPlaying(bool on) async {
    playing = on;
    _setEnabled(media, on);
  }

  @override
  Future<void> unsubscribe() => media.unsubscribe();
}

/// Sets the media track's enabled flag directly (LiveKit's own enable and
/// disable do nothing on a track it has not started) and checks it took:
/// a track that cannot be disabled must not be used.
void _setEnabled(LiveKitMedia media, bool enabled) {
  media.enabled = enabled;
  if (media.enabled != enabled) {
    throw StateError('media track did not change state');
  }
}
