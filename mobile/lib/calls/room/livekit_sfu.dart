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
///    never starts is unsubscribed;
///  - a remote mute or unmute of a local track (B6 review, round 9): B6
///    never mutes its own tracks through LiveKit, so any such change comes
///    from the SFU, whose later unmute would restart or re-enable the
///    capture on a sender that may not carry a cryptor yet, or switch on a
///    microphone the person muted. Every local track is cut from its RTP
///    senders inside the event's callback and the call ends;
///  - a camera or screen published on anything but one VP8 sender with
///    dynacast off ends the call: the SFU can move the codec, and with
///    dynacast on (LiveKit turns it on for SVC codecs) it can ask for a
///    backup codec, which LiveKit then sends on a second RTP sender with no
///    cryptor, whatever the publish options say;
///  - every capture this connection published is stopped when it is
///    unpublished and when the connection ends, also one whose publish
///    finished after the room was gone.
class LiveKitSfuConnection implements SfuConnection {
  LiveKitSfuConnection(
    WebRtcFrameKeys keys, {
    LiveKitRoomDriver? driver,
    this.remoteStartWait = const Duration(seconds: 10),
  }) : _driver = driver ?? _LkRoomDriver(keys);

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
  bool _closed = false;
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
      case LiveKitLocalMuteChanged(:final media):
        // Cut first: LiveKit's own unmute must find no sender to restart
        // or re-enable the capture on.
        _cut(media);
        for (final track in _local) {
          _cut(track.media);
        }
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

  static void _cut(LiveKitLocalMedia? media) {
    if (media == null) return;
    _disable(media);
    try {
      media.cutSenders();
    } catch (_) {}
  }

  static Future<void> _stop(LiveKitLocalMedia media) async {
    try {
      await media.stop();
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
  Future<SfuLocalTrack> publishDisabled(int slot, {String? sourceId}) async {
    if (slot != roomSlotVoice &&
        slot != roomSlotCamera &&
        slot != roomSlotScreen) {
      // Screen audio has no capture path on any platform yet.
      throw UnsupportedError('slot $slot is not published');
    }
    if (_poisoned || _closed) {
      throw StateError('the SFU connection is not fail closed');
    }
    final LiveKitLocalMedia media;
    _publishing++;
    try {
      media = slot == roomSlotVoice
          ? await _driver.publishVoiceDisabled()
          : await _driver.publishVideoDisabled(slot, sourceId);
      _awaitingCryptor.add(media.sid);
    } finally {
      _publishing--;
    }
    if (_closed) {
      // The publish finished after the call ended: release the capture.
      _disable(media);
      _awaitingCryptor.remove(media.sid);
      await _stop(media);
      throw StateError('the SFU connection is closed');
    }
    final track = _LiveKitLocalTrack(this, media, slot);
    _local.add(track);
    if (_poisoned || media.enabled) {
      _disable(media);
      throw StateError('the SFU connection is not fail closed');
    }
    if (slot != roomSlotVoice &&
        (media.codec != roomVideoCodec ||
            media.extraSenders != 0 ||
            _driver.dynacast)) {
      // Not the one VP8 sender asked for: the SFU moved the codec or made
      // room for a backup codec sender that would carry no cryptor. The
      // capture is still disabled; it is cut, unpublished and stopped, and
      // the call ends (dynacast stays on for the room once LiveKit set it).
      _cut(media);
      _failClosedNow();
      try {
        await unpublish(track);
      } catch (_) {}
      throw StateError('video was not published on one VP8 sender');
    }
    return track;
  }

  @override
  Future<void> unpublish(SfuLocalTrack track) async {
    final local = track as _LiveKitLocalTrack;
    _disable(local.media);
    _local.remove(local);
    _awaitingCryptor.remove(local.sid);
    try {
      await _driver.unpublish(local.sid);
    } finally {
      // The camera light goes out even if LiveKit no longer knows the track.
      await _stop(local.media);
    }
  }

  @override
  Future<RoomFrameCryptor> senderCryptor(
    SfuLocalTrack track,
    String participantId,
  ) async {
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
    SfuRemoteTrack track,
    String participantId,
  ) async {
    final receiver = (track as _LiveKitRemoteTrack).media.receiver;
    if (receiver == null) throw StateError('track has no receiver');
    return _driver.receiverCryptor(receiver, participantId);
  }

  @override
  Future<void> sendData(Uint8List data) => _driver.publishData(data);

  @override
  Future<void> disconnect() async {
    _closed = true;
    for (final track in _local) {
      _disable(track.media);
    }
    _starting.clear();
    try {
      await _driver.disconnect();
    } finally {
      for (final track in _local.toList()) {
        await _stop(track.media);
      }
      _local.clear();
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

  /// Fires when the capture ends by itself.
  Stream<void> get ended;

  /// The capture's stream for a camera preview, or null.
  Object? get preview;

  /// The RTP sender carrying it now (a full reconnect replaces it).
  Object? get sender;

  /// The video codec LiveKit published it with (null for voice).
  String? get codec;

  /// RTP senders beyond [sender] carrying this capture (backup codecs).
  int get extraSenders;

  /// Detaches the capture from every RTP sender it has, synchronously, so
  /// that nothing LiveKit does to the track afterwards reaches the network.
  void cutSenders();

  /// Stops the capture (the camera light, the screen, the microphone).
  /// Stopping twice is harmless.
  Future<void> stop();
}

abstract interface class LiveKitRemoteMedia implements LiveKitMedia {
  String get sid;

  /// The SFU identity of the participant that publishes it.
  String get participant;

  /// Whether LiveKit has started it (its start enables it).
  bool get isActive;
  bool get isVideo;
  Object? get stream;
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

/// A local track was muted or unmuted by someone other than B6 (which never
/// mutes its own tracks through LiveKit): the SFU.
class LiveKitLocalMuteChanged extends LiveKitRoomEvent {
  const LiveKitLocalMuteChanged(this.sid, this.media);
  final String sid;
  final LiveKitLocalMedia? media;
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

  /// Whether the room runs dynacast now. B6 turns it off; LiveKit turns it
  /// on by itself when it publishes an SVC codec.
  bool get dynacast;
  Future<void> connect(
    String url,
    String token,
    void Function(LiveKitRoomEvent) onEvent,
  );

  /// Creates the voice capture, starts and disables it, then publishes it.
  Future<LiveKitLocalMedia> publishVoiceDisabled();

  /// The same for the camera ([roomSlotCamera]) or a shared screen or window
  /// ([roomSlotScreen], [sourceId] on desktop), published with
  /// [roomCameraPublishOptions] or [roomScreenPublishOptions]. Throws
  /// [SfuCaptureDenied] when the capture cannot be created.
  Future<LiveKitLocalMedia> publishVideoDisabled(int slot, String? sourceId);
  Future<void> unpublish(String sid);
  Future<void> publishData(Uint8List data);
  Future<void> disconnect();
  Future<RoomFrameCryptor> senderCryptor(Object sender, String participantId);
  Future<RoomFrameCryptor> receiverCryptor(
    Object receiver,
    String participantId,
  );
}

/// The only video codec B6 sends (S1 checks its clear bytes and IVs).
const roomVideoCodec = 'vp8';

/// Camera publish options, fixed and test-visible (B6 fail-closed rules):
///  - one layer: simulcast runs up to three encoders under one frame key, and
///    the design asks S1 to confirm the IV never repeats across them first;
///  - no backup codec: it would add a second RTP sender that carries no
///    frame cryptor;
///  - VP8, the codec every platform has.
const roomCameraPublishOptions = lk.VideoPublishOptions(
  videoCodec: roomVideoCodec,
  simulcast: false,
  backupVideoCodec: lk.BackupVideoCodec(enabled: false),
  videoEncoding: lk.VideoEncoding(maxBitrate: 600000, maxFramerate: 24),
);

/// Screen share publish options: the same fixed rules, at 15 frames a second.
const roomScreenPublishOptions = lk.VideoPublishOptions(
  videoCodec: roomVideoCodec,
  simulcast: false,
  backupVideoCodec: lk.BackupVideoCodec(enabled: false),
  screenShareEncoding: lk.VideoEncoding(maxBitrate: 1500000, maxFramerate: 15),
);

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
  final Map<String, StreamController<void>> _ended = {};

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
  bool get dynacast => _room.roomOptions.dynacast;

  @override
  Future<void> connect(
    String url,
    String token,
    void Function(LiveKitRoomEvent) onEvent,
  ) async {
    final listener = _listener = _room.createListener();
    listener
      ..on<lk.RoomReconnectingEvent>(
        (_) => onEvent(const LiveKitReconnecting()),
      )
      ..on<lk.RoomDisconnectedEvent>(
        (_) => onEvent(const LiveKitDisconnected()),
      )
      ..on<lk.LocalTrackPublishedEvent>((event) {
        final track = event.publication.track;
        onEvent(
          LiveKitLocalTrackPublished(
            event.publication.sid,
            track == null ? null : _LkLocalMedia(track, event.publication.sid),
          ),
        );
      })
      ..on<lk.TrackMutedEvent>((event) {
        if (event.participant is! lk.LocalParticipant) return;
        final track = event.publication.track;
        onEvent(
          LiveKitLocalMuteChanged(
            event.publication.sid,
            track is lk.LocalTrack
                ? _LkLocalMedia(track, event.publication.sid)
                : null,
          ),
        );
      })
      ..on<lk.TrackUnmutedEvent>((event) {
        if (event.participant is! lk.LocalParticipant) return;
        final track = event.publication.track;
        onEvent(
          LiveKitLocalMuteChanged(
            event.publication.sid,
            track is lk.LocalTrack
                ? _LkLocalMedia(track, event.publication.sid)
                : null,
          ),
        );
      })
      ..on<lk.LocalTrackUnpublishedEvent>((event) {
        final controller = _ended.remove(event.publication.sid);
        if (controller == null) return;
        controller.add(null);
        unawaited(controller.close());
      })
      ..on<lk.TrackSubscribedEvent>(
        (event) => onEvent(
          LiveKitTrackSubscribed(
            _LkRemoteMedia(event.participant, event.publication, event.track),
          ),
        ),
      )
      ..on<lk.TrackUnsubscribedEvent>(
        (event) => onEvent(LiveKitTrackUnsubscribed(event.publication.sid)),
      )
      ..on<lk.DataReceivedEvent>(
        (event) => onEvent(
          LiveKitDataReceived(
            event.participant?.identity,
            Uint8List.fromList(event.data),
          ),
        ),
      );
    await _room.connect(
      url,
      token,
      connectOptions: const lk.ConnectOptions(autoSubscribe: true),
    );
  }

  @override
  Future<LiveKitLocalMedia> publishVoiceDisabled() async {
    final participant = _room.localParticipant;
    if (participant == null) throw StateError('not connected');
    final track = await lk.LocalAudioTrack.create(
      const lk.AudioCaptureOptions(),
    );
    // Started and disabled before it is published: until its cryptor holds
    // a key the encoder sees silence only (publishing does not re-enable a
    // started track).
    await track.start();
    _setEnabled(_LkLocalMedia(track, ''), false);
    final publication = await participant.publishAudioTrack(
      track,
      publishOptions: _voiceOptions,
    );
    return _LkLocalMedia(track, publication.sid);
  }

  @override
  Future<LiveKitLocalMedia> publishVideoDisabled(
    int slot,
    String? sourceId,
  ) async {
    final participant = _room.localParticipant;
    if (participant == null) throw StateError('not connected');
    final lk.LocalVideoTrack track;
    try {
      track = slot == roomSlotCamera
          ? await lk.LocalVideoTrack.createCameraTrack(
              const lk.CameraCaptureOptions(
                params: lk.VideoParametersPresets.h540_169,
                maxFrameRate: 24,
              ),
            )
          : await lk.LocalVideoTrack.createScreenShareTrack(
              lk.ScreenShareCaptureOptions(
                sourceId: sourceId,
                maxFrameRate: 15,
                params: lk.VideoParametersPresets.screenShareH1080FPS15,
              ),
            );
    } catch (_) {
      // Permission refused, no camera, the picker cancelled. Nothing is open.
      throw const SfuCaptureDenied();
    }
    // Started and disabled before it is published, as for voice: until its
    // cryptor holds a key the encoder sees black frames only.
    final media = _LkLocalMedia(track, '');
    String? sid;
    try {
      await track.start();
      _setEnabled(media, false);
      final publication = await participant.publishVideoTrack(
        track,
        publishOptions: slot == roomSlotCamera
            ? roomCameraPublishOptions
            : roomScreenPublishOptions,
      );
      sid = publication.sid;
      // LiveKit unpublishes a track whose capture ended by itself (the user
      // stopped sharing, the window closed): that is the end signal.
      final ended =
          _ended[publication.sid] = StreamController<void>.broadcast();
      return _LkLocalMedia(track, publication.sid, ended.stream);
    } catch (_) {
      // Never leave a capture (the camera light, the screen) running, or a
      // publication behind.
      if (sid != null) {
        try {
          await participant.removePublishedTrack(sid);
        } catch (_) {}
      }
      try {
        await track.stop();
      } catch (_) {}
      rethrow;
    }
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
    Object sender,
    String participantId,
  ) async =>
      _Cryptor(
        await rtc.frameCryptorFactory.createFrameCryptorForRtpSender(
          participantId: participantId,
          sender: sender as rtc.RTCRtpSender,
          algorithm: rtc.Algorithm.kAesGcm,
          keyProvider: keys.provider,
        ),
      );

  @override
  Future<RoomFrameCryptor> receiverCryptor(
    Object receiver,
    String participantId,
  ) async =>
      _Cryptor(
        await rtc.frameCryptorFactory.createFrameCryptorForRtpReceiver(
          participantId: participantId,
          receiver: receiver as rtc.RTCRtpReceiver,
          algorithm: rtc.Algorithm.kAesGcm,
          keyProvider: keys.provider,
        ),
      );

  @override
  Future<void> disconnect() async {
    await _listener?.dispose();
    _listener = null;
    for (final controller in _ended.values) {
      unawaited(controller.close());
    }
    _ended.clear();
    await _room.disconnect();
    await _room.dispose();
  }
}

class _LkLocalMedia implements LiveKitLocalMedia {
  _LkLocalMedia(this.track, this.sid, [this.ended = const Stream.empty()]);
  final lk.LocalTrack track;
  @override
  final String sid;

  @override
  final Stream<void> ended;

  @override
  Object? get preview =>
      track.kind == lk.TrackType.VIDEO && track.source == lk.TrackSource.camera
          ? track.mediaStream
          : null;

  @override
  bool get enabled => track.mediaStreamTrack.enabled;
  @override
  set enabled(bool on) => track.mediaStreamTrack.enabled = on;

  @override
  Object? get sender => track.sender;

  @override
  String? get codec => track.kind == lk.TrackType.VIDEO ? track.codec : null;

  @override
  int get extraSenders {
    final video = track;
    if (video is! lk.LocalVideoTrack) return 0;
    return video.simulcastCodecs.values.where((s) => s.sender != null).length;
  }

  /// Read in `livekit_client` 2.13.2: `LocalTrack.restartTrack` (an unmute)
  /// refuses to run without `transceiver.sender`, and backup codec senders
  /// are reached only through `simulcastCodecs[..].sender`. With both gone
  /// and every sender's track replaced by none, a later `enable()` turns on
  /// a capture no sender carries.
  @override
  void cutSenders() {
    final senders = <rtc.RTCRtpSender>[
      if (track.sender != null) track.sender!,
    ];
    track.transceiver = null;
    final video = track;
    if (video is lk.LocalVideoTrack) {
      for (final simulcast in video.simulcastCodecs.values) {
        final sender = simulcast.sender;
        if (sender != null) senders.add(sender);
        simulcast.sender = null;
      }
    }
    for (final sender in senders) {
      unawaited(sender.replaceTrack(null).catchError((Object _) {}));
    }
  }

  @override
  Future<void> stop() async {
    await track.stop();
  }
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
  bool get isVideo => track.kind == lk.TrackType.VIDEO;

  @override
  Object? get stream => track.mediaStream;

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
  Stream<void> get ended => media.ended;

  @override
  Object? get preview => media.preview;

  @override
  Future<void> setEnabled(bool enabled) async {
    if (enabled && _connection._poisoned) {
      _setEnabled(media, false);
      throw StateError('the SFU connection is not fail closed');
    }
    if (enabled &&
        slot != roomSlotVoice &&
        (media.extraSenders != 0 || _connection._driver.dynacast)) {
      // A second sender (a backup codec) appeared after the publish check.
      LiveKitSfuConnection._cut(media);
      _connection._failClosedNow();
      throw StateError('video gained a sender with no cryptor');
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
  bool get isVideo => media.isVideo;

  @override
  Object? get stream => media.stream;

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
