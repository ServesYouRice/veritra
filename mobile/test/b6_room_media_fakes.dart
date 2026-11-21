import 'dart:async';
import 'dart:typed_data';

import 'package:private_messenger/calls/room/room_capture.dart';
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_media.dart';
import 'package:private_messenger/calls/room/room_ports.dart';
import 'package:private_messenger/calls/room/webrtc_frame_keys.dart';

import 'b6_room_fakes.dart';

// Fakes of the SFU, the frame cryptor and the platform capture, shared by the
// B6 media transport tests.

class FakeCryptor implements RoomFrameCryptor {
  FakeCryptor(this.participantId, this.log, {this.failEnable = false});
  final String participantId;
  final List<String> log;
  final bool failEnable;
  bool enabled = false;
  bool disposed = false;
  int? keyIndex;

  @override
  Future<bool> setEnabled(bool on) async {
    log.add('cryptor $participantId enabled=$on');
    if (failEnable && on) return false;
    enabled = on;
    return true;
  }

  @override
  Future<bool> setKeyIndex(int index) async {
    log.add('cryptor $participantId index=$index');
    keyIndex = index;
    return true;
  }

  @override
  Future<void> dispose() async {
    log.add('cryptor $participantId disposed');
    disposed = true;
  }
}

class FakeLocalTrack implements SfuLocalTrack {
  FakeLocalTrack(this.sid, this.slot, this.log);
  @override
  final String sid;
  @override
  final int slot;
  final List<String> log;
  bool enabled = false;
  final StreamController<void> endedController =
      StreamController<void>.broadcast();
  @override
  Stream<void> get ended => endedController.stream;
  @override
  Object? get preview => slot == roomSlotCamera ? 'preview_$sid' : null;
  @override
  Future<void> setEnabled(bool on) async {
    enabled = on;
    log.add('track $sid enabled=$on');
  }
}

class FakeRemoteTrack implements SfuRemoteTrack {
  FakeRemoteTrack(this.sid, this.participant, {this.isVideo = false});
  @override
  final String sid;
  @override
  final String participant;
  @override
  final bool isVideo;
  @override
  Object? get stream => isVideo ? 'stream_$sid' : null;
  bool playing = true; // what a raw subscription would do
  bool unsubscribed = false;
  bool refusesMute = false;
  @override
  Future<void> setPlaying(bool on) async {
    if (!on && refusesMute) throw StateError('cannot mute');
    playing = on;
  }

  @override
  Future<void> unsubscribe() async => unsubscribed = true;
}

class FakeHub {
  final List<FakeSfu> live = [];
}

class FakeSfu implements SfuConnection {
  FakeSfu(this.hub, this.identity);
  final FakeHub hub;
  final String identity;
  final List<String> log = [];
  final StreamController<SfuEvent> _events = StreamController.broadcast();
  final List<FakeLocalTrack> published = [];
  final Map<String, FakeRemoteTrack> remote = {};
  final List<FakeCryptor> cryptors = [];
  final List<Uint8List> sent = [];
  bool failSenderEnable = false;
  bool failReceiverEnable = false;
  bool connected = false;

  void emit(SfuEvent event) => _events.add(event);

  @override
  Stream<SfuEvent> get events => _events.stream;

  @override
  String? get localIdentity => connected ? identity : null;

  @override
  Future<void> connect(String url, String token) async {
    log.add('connect');
    connected = true;
    hub.live.add(this);
    for (final other in hub.live) {
      if (other == this) continue;
      for (final track in other.published) {
        _subscribe(track.sid, other.identity);
      }
    }
  }

  void _subscribe(String sid, String from, {bool video = false}) {
    final track = remote[sid] = FakeRemoteTrack(sid, from, isVideo: video);
    emit(SfuTrackSubscribed(track));
  }

  /// A capture the platform refuses for these slots (permission denied).
  final Set<int> denySlots = {};
  String? lastSourceId;
  Completer<void>? holdCapture;

  @override
  Future<SfuLocalTrack> publishDisabled(int slot, {String? sourceId}) async {
    log.add('publish $slot');
    lastSourceId = sourceId;
    if (holdCapture != null) await holdCapture!.future;
    if (denySlots.contains(slot)) throw const SfuCaptureDenied();
    final track = FakeLocalTrack('TR_${identity}_$slot', slot, log);
    published.add(track);
    for (final other in hub.live) {
      if (other != this) {
        other._subscribe(track.sid, identity, video: slot != roomSlotVoice);
      }
    }
    return track;
  }

  @override
  Future<void> unpublish(SfuLocalTrack track) async {
    log.add('unpublish ${track.sid}');
    published.remove(track);
    for (final other in hub.live) {
      if (other != this) {
        other.remote.remove(track.sid);
        other.emit(SfuTrackUnsubscribed(track.sid));
      }
    }
  }

  @override
  Future<RoomFrameCryptor> senderCryptor(
    SfuLocalTrack track,
    String participantId,
  ) async {
    log.add('sender cryptor $participantId');
    final c = FakeCryptor(participantId, log, failEnable: failSenderEnable);
    cryptors.add(c);
    return c;
  }

  @override
  Future<RoomFrameCryptor> receiverCryptor(
    SfuRemoteTrack track,
    String participantId,
  ) async {
    log.add('receiver cryptor ${track.sid} $participantId');
    final c = FakeCryptor(participantId, log, failEnable: failReceiverEnable);
    cryptors.add(c);
    return c;
  }

  @override
  Future<void> sendData(Uint8List data) async {
    sent.add(data);
    for (final other in hub.live) {
      if (other != this) other.emit(SfuData(identity, data));
    }
  }

  @override
  Future<void> disconnect() async {
    log.add('disconnect');
    hub.live.remove(this);
  }

  FakeCryptor? receiverFor(String sid) => cryptors
      .where(
        (c) =>
            !c.disposed &&
            log.contains('receiver cryptor $sid ${c.participantId}'),
      )
      .lastOrNull;
}

class MediaDevice {
  MediaDevice._(
    this.self,
    this.crypto,
    this.api,
    this.keys,
    this.provider,
    this.engine,
    this.sfu,
    this.media,
  );
  final CallMember self;
  final FakeCrypto crypto;
  final FakeApi api;
  final WebRtcFrameKeys keys;
  final FakeKeyProvider provider;
  final RoomEngine engine;
  final FakeSfu sfu;
  final RoomMediaSession media;

  static Future<MediaDevice> create(
    String name,
    FakeServer server,
    FakeClock clock,
    FakeParent parent,
    FakeHub hub, {
    RoomCapture capture = const NoRoomCapture(),
    int videoCap = roomVideoCap,
  }) async {
    final self = member(name);
    final crypto = FakeCrypto(self);
    final api = FakeApi(server, self);
    final log = <String>[];
    final provider = FakeKeyProvider(log);
    final keys = await WebRtcFrameKeys.open(create: (_) async => provider);
    final engine = RoomEngine(
      api: api,
      crypto: crypto,
      parent: parent,
      keys: keys,
      scheduler: clock,
      selfAccountId: self.accountId,
      selfDeviceId: self.deviceId,
    );
    final sfu = FakeSfu(hub, 'sfu_$name');
    final media = RoomMediaSession(
      engine: engine,
      keys: keys,
      sfu: sfu,
      capture: capture,
      videoCap: videoCap,
    )..start();
    return MediaDevice._(self, crypto, api, keys, provider, engine, sfu, media);
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await pump();
      await keys.idle;
      await media.idle;
    }
  }
}
