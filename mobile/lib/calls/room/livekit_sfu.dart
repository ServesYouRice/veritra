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
/// the MLS-derived keys in [keys], and binds tracks by sealed announcements
/// ([RoomMediaSession]). The room therefore runs without `e2eeOptions`, and
/// voice is published with DTX and RED off (O4).
class LiveKitSfuConnection implements SfuConnection {
  LiveKitSfuConnection(this.keys);

  final WebRtcFrameKeys keys;
  final lk.Room _room = lk.Room(
    roomOptions: const lk.RoomOptions(
      adaptiveStream: false,
      dynacast: false,
      defaultAudioPublishOptions: _voiceOptions,
    ),
  );
  final StreamController<SfuEvent> _events =
      StreamController<SfuEvent>.broadcast();
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
  Stream<SfuEvent> get events => _events.stream;

  @override
  Future<void> connect(String url, String token) async {
    final listener = _listener = _room.createListener();
    listener
      ..on<lk.TrackSubscribedEvent>((event) {
        // Muted here, synchronously, before the event crosses the stream:
        // nothing plays until the session binds the track through MLS.
        try {
          _setTrackEnabled(event.track, false);
        } catch (_) {
          event.publication.unsubscribe();
          return;
        }
        _events.add(SfuTrackSubscribed(_LiveKitRemoteTrack(
            event.participant, event.publication, event.track)));
      })
      ..on<lk.TrackUnsubscribedEvent>((event) {
        _events.add(SfuTrackUnsubscribed(event.publication.sid));
      })
      ..on<lk.DataReceivedEvent>((event) {
        _events.add(SfuData(
            event.participant?.identity, Uint8List.fromList(event.data)));
      })
      ..on<lk.RoomDisconnectedEvent>((_) {
        _events.add(const SfuDisconnected());
      });
    await _room.connect(url, token,
        connectOptions: const lk.ConnectOptions(autoSubscribe: true));
  }

  @override
  Future<SfuLocalTrack> publishDisabled(int slot) async {
    if (slot != roomSlotVoice) {
      throw UnsupportedError('only voice is published (camera and screen '
          'share are not built)');
    }
    final participant = _room.localParticipant;
    if (participant == null) throw StateError('not connected');
    final track =
        await lk.LocalAudioTrack.create(const lk.AudioCaptureOptions());
    // Started and disabled before it is published: until its cryptor holds
    // a key the encoder sees silence only (publishing does not re-enable a
    // started track).
    await track.start();
    _setTrackEnabled(track, false);
    final publication = await participant.publishAudioTrack(track,
        publishOptions: _voiceOptions);
    return _LiveKitLocalTrack(track, publication.sid, slot);
  }

  @override
  Future<void> unpublish(SfuLocalTrack track) async {
    final local = track as _LiveKitLocalTrack;
    await _room.localParticipant?.removePublishedTrack(local.sid);
  }

  @override
  Future<RoomFrameCryptor> senderCryptor(
      SfuLocalTrack track, String participantId) async {
    final sender = (track as _LiveKitLocalTrack).track.sender;
    if (sender == null) throw StateError('track has no sender');
    return _Cryptor(
        await rtc.frameCryptorFactory.createFrameCryptorForRtpSender(
      participantId: participantId,
      sender: sender,
      algorithm: rtc.Algorithm.kAesGcm,
      keyProvider: keys.provider,
    ));
  }

  @override
  Future<RoomFrameCryptor> receiverCryptor(
      SfuRemoteTrack track, String participantId) async {
    final receiver = (track as _LiveKitRemoteTrack).track.receiver;
    if (receiver == null) throw StateError('track has no receiver');
    return _Cryptor(
        await rtc.frameCryptorFactory.createFrameCryptorForRtpReceiver(
      participantId: participantId,
      receiver: receiver,
      algorithm: rtc.Algorithm.kAesGcm,
      keyProvider: keys.provider,
    ));
  }

  @override
  Future<void> sendData(Uint8List data) async {
    await _room.localParticipant?.publishData(data, reliable: true);
  }

  @override
  Future<void> disconnect() async {
    await _listener?.dispose();
    _listener = null;
    await _room.disconnect();
    await _room.dispose();
    await _events.close();
  }
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
  _LiveKitLocalTrack(this.track, this.sid, this.slot);
  final lk.LocalAudioTrack track;
  @override
  final String sid;
  @override
  final int slot;

  @override
  Future<void> setEnabled(bool enabled) async =>
      _setTrackEnabled(track, enabled);
}

class _LiveKitRemoteTrack implements SfuRemoteTrack {
  _LiveKitRemoteTrack(this._participant, this._publication, this.track);
  final lk.RemoteParticipant _participant;
  final lk.RemoteTrackPublication _publication;
  final lk.Track track;

  @override
  String get sid => _publication.sid;

  @override
  String get participant => _participant.identity;

  @override
  Future<void> setPlaying(bool playing) async =>
      _setTrackEnabled(track, playing);

  @override
  Future<void> unsubscribe() => _publication.unsubscribe();
}

/// Sets the media track's enabled flag directly (LiveKit's own enable and
/// disable do nothing on a track it has not started) and checks it took:
/// a track that cannot be disabled must not be used.
void _setTrackEnabled(lk.Track track, bool enabled) {
  track.mediaStreamTrack.enabled = enabled;
  if (track.mediaStreamTrack.enabled != enabled) {
    throw StateError('media track did not change state');
  }
}
