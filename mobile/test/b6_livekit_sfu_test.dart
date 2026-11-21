import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/livekit_sfu.dart';
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_media.dart';
import 'package:private_messenger/calls/room/webrtc_frame_keys.dart';

import 'b6_room_fakes.dart';

// B6 review HIGH and MEDIUM (round 7): the LiveKit adapter keeps media fail
// closed around LiveKit's own reconnect, republish and track start, driven
// by a fake room that calls the adapter as LiveKit's listener would.

class FakeLocalMedia implements LiveKitLocalMedia {
  FakeLocalMedia(this.sid);
  @override
  final String sid;
  @override
  bool enabled = true; // a started capture
  @override
  Object? sender = Object();
  @override
  Stream<void> get ended => const Stream.empty();
  @override
  Object? get preview => null;
}

class FakeRemoteMedia implements LiveKitRemoteMedia {
  FakeRemoteMedia(this.sid, this.participant);
  @override
  final String sid;
  @override
  final String participant;
  @override
  bool enabled = true;
  @override
  bool isActive = false;
  @override
  bool get isVideo => false;
  @override
  Object? get stream => null;
  @override
  final Object receiver = Object();
  bool unsubscribed = false;
  @override
  Future<void> unsubscribe() async => unsubscribed = true;
}

class FakeTestCryptor implements RoomFrameCryptor {
  FakeTestCryptor(this.target);
  final Object target;
  bool enabled = false;
  bool disposed = false;
  @override
  Future<bool> setEnabled(bool on) async => enabled = on;
  @override
  Future<bool> setKeyIndex(int index) async => true;
  @override
  Future<void> dispose() async => disposed = true;
}

class FakeRoom implements LiveKitRoomDriver {
  void Function(LiveKitRoomEvent)? _on;
  final List<FakeLocalMedia> published = [];
  final List<Uint8List> sent = [];
  final List<FakeTestCryptor> cryptors = [];
  bool disconnected = false;
  int _sids = 0;

  /// LiveKit delivers its events on an asynchronous stream: the adapter's
  /// callback runs in a later microtask, never inside the emitting call.
  void deliver(LiveKitRoomEvent event) => scheduleMicrotask(() => _on!(event));

  @override
  String? get localIdentity => _on == null ? null : 'sfu_self';

  @override
  Future<void> connect(
    String url,
    String token,
    void Function(LiveKitRoomEvent) onEvent,
  ) async {
    _on = onEvent;
  }

  @override
  Future<LiveKitLocalMedia> publishVoiceDisabled() async {
    final media = FakeLocalMedia('TR_${++_sids}')..enabled = false;
    published.add(media);
    // LiveKit announces the publication while publishing.
    deliver(LiveKitLocalTrackPublished(media.sid, media));
    await Future<void>.delayed(Duration.zero);
    return media;
  }

  @override
  Future<LiveKitLocalMedia> publishVideoDisabled(
    int slot,
    String? sourceId,
  ) async {
    videoRequests.add((slot, sourceId));
    if (denyVideo) throw const SfuCaptureDenied();
    return publishVoiceDisabled();
  }

  final List<(int, String?)> videoRequests = [];
  bool denyVideo = false;

  /// What LiveKit does on `EngineRestartedEvent`: the same track published
  /// again on a new RTP sender, with no frame cryptor.
  void republish(FakeLocalMedia media) {
    media.sender = Object();
    deliver(LiveKitLocalTrackPublished('${media.sid}_again', media));
  }

  /// What LiveKit does when a remote track arrives: the subscribed event,
  /// then `await track.start()`, which marks it active and enables it.
  void subscribe(FakeRemoteMedia media, {bool starts = true}) {
    deliver(LiveKitTrackSubscribed(media));
    if (!starts) return;
    () async {
      await Future<void>.value(); // startCapture()
      media.isActive = true;
      await Future<void>.value();
      media.enabled = true; // RemoteTrack.start -> enable()
    }();
  }

  @override
  Future<void> unpublish(String sid) async {}

  @override
  Future<void> publishData(Uint8List data) async => sent.add(data);

  @override
  Future<void> disconnect() async => disconnected = true;

  @override
  Future<RoomFrameCryptor> senderCryptor(
    Object sender,
    String participantId,
  ) async {
    final c = FakeTestCryptor(sender);
    cryptors.add(c);
    return c;
  }

  @override
  Future<RoomFrameCryptor> receiverCryptor(
    Object receiver,
    String participantId,
  ) async {
    final c = FakeTestCryptor(receiver);
    cryptors.add(c);
    return c;
  }
}

/// Waits until [done] holds, up to [limit] (real time: the adapter polls
/// with timers), so a loaded machine does not fail the test.
Future<void> eventually(
  bool Function() done, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final waited = Stopwatch()..start();
  while (!done() && waited.elapsed < limit) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> microtasks() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.value();
  }
}

void main() {
  late FakeRoom room;
  late LiveKitSfuConnection sfu;
  late WebRtcFrameKeys keys;
  late List<SfuEvent> events;

  setUp(() async {
    room = FakeRoom();
    keys = await WebRtcFrameKeys.open(
      create: (_) async => FakeKeyProvider(<String>[]),
    );
    sfu = LiveKitSfuConnection(
      keys,
      driver: room,
      remoteStartWait: const Duration(milliseconds: 200),
    );
    events = <SfuEvent>[];
    sfu.events.listen(events.add);
    await sfu.connect('wss://sfu.test', 'token');
  });

  /// The session's order: publish disabled, attach the cryptor, enable.
  Future<SfuLocalTrack> publishVoice() async {
    final track = await sfu.publishDisabled(roomSlotVoice);
    await sfu.senderCryptor(track, 'acct_a/dev_a:0');
    await track.setEnabled(true);
    await microtasks();
    return track;
  }

  test(
    'its own publish passes: no failure, the voice opens once keyed',
    () async {
      await publishVoice();
      expect(room.published.single.enabled, isTrue);
      expect(sfu.poisoned, isFalse);
      expect(events.whereType<SfuDisconnected>(), isEmpty);
    },
  );

  test(
      'a reconnect disables the voice inside the event callback, and nothing '
      'enables or publishes it on that connection again', () async {
    final track = await publishVoice();
    final media = room.published.single;
    // Run the event callback exactly as LiveKit's listener would, and look
    // before anything else gets a turn.
    var disabledInCallback = false;
    scheduleMicrotask(() {
      room._on!(const LiveKitReconnecting());
      disabledInCallback = !media.enabled;
    });
    await Future<void>.value();
    expect(disabledInCallback, isTrue);
    await microtasks();
    expect(events.whereType<SfuDisconnected>(), hasLength(1));
    expect(sfu.poisoned, isTrue);
    // A queued enable (a key switch or an unmute) is refused and leaves the
    // capture off.
    await expectLater(track.setEnabled(true), throwsStateError);
    expect(media.enabled, isFalse);
    await expectLater(sfu.publishDisabled(roomSlotVoice), throwsStateError);
    // LiveKit's republish after the reconnect is caught as well.
    room.republish(media);
    await microtasks();
    expect(media.enabled, isFalse);
  });

  test(
      'a republish on a sender with no cryptor of ours, with no reconnect '
      'event, disables it and ends the call', () async {
    await publishVoice();
    final media = room.published.single;
    room.republish(media);
    await microtasks();
    expect(media.enabled, isFalse);
    expect(sfu.poisoned, isTrue);
    expect(events.whereType<SfuDisconnected>(), hasLength(1));
    // An unknown track published enabled, too.
    final stray = FakeLocalMedia('TR_stray');
    room.deliver(LiveKitLocalTrackPublished(stray.sid, stray));
    await microtasks();
    expect(stray.enabled, isFalse);
  });

  test(
      'a subscribed track that LiveKit starts (and so enables) stays muted, '
      'and reaches the session only after that', () async {
    final media = FakeRemoteMedia('TR_b', 'sfu_b');
    room.subscribe(media);
    await microtasks();
    // LiveKit's start has run and enabled it; the adapter has not handed it
    // over yet.
    expect(media.isActive, isTrue);
    expect(events.whereType<SfuTrackSubscribed>(), isEmpty);
    await eventually(() => events.whereType<SfuTrackSubscribed>().isNotEmpty);
    expect(events.whereType<SfuTrackSubscribed>(), hasLength(1));
    expect(
      media.enabled,
      isFalse,
      reason: 'disabled again after LiveKit started it',
    );
    final track = events.whereType<SfuTrackSubscribed>().single.track;
    await track.setPlaying(true);
    expect(media.enabled, isTrue);
    await track.setPlaying(false);
    expect(media.enabled, isFalse);
  });

  test(
    'a subscribed track that never starts is unsubscribed, never played',
    () async {
      final media = FakeRemoteMedia('TR_b', 'sfu_b');
      room.subscribe(media, starts: false);
      await eventually(() => media.unsubscribed);
      expect(media.unsubscribed, isTrue);
      expect(events.whereType<SfuTrackSubscribed>(), isEmpty);
      expect(media.enabled, isFalse);
    },
  );

  test('a reconnect ends the call through the session and engine', () async {
    final server = FakeServer('conv_1');
    final clock = FakeClock();
    final self = member('a');
    final engine = RoomEngine(
      api: FakeApi(server, self),
      crypto: FakeCrypto(self),
      parent: FakeParent([member('a')]),
      keys: keys,
      scheduler: clock,
      selfAccountId: self.accountId,
      selfDeviceId: self.deviceId,
    );
    final callRoom = FakeRoom();
    final callSfu = LiveKitSfuConnection(keys, driver: callRoom);
    final media = RoomMediaSession(engine: engine, keys: keys, sfu: callSfu)
      ..start();
    await engine.join('conv_1');
    for (var i = 0; i < 6; i++) {
      await pump();
      await keys.idle;
      await media.idle;
    }
    expect(engine.phase, RoomPhase.active);
    final voice = callRoom.published.single;
    expect(voice.enabled, isTrue);
    callRoom.deliver(const LiveKitReconnecting());
    await pump();
    expect(voice.enabled, isFalse);
    for (var i = 0; i < 6; i++) {
      await pump();
      await media.idle;
    }
    expect(engine.phase, RoomPhase.failed);
    expect(engine.failure, RoomFailure.cryptorNotFailClosed);
    expect(callRoom.disconnected, isTrue);
    expect(voice.enabled, isFalse);
    engine.dispose();
  });

  group('video', () {
    test('camera and screen are published disabled and need their cryptor',
        () async {
      final camera = await sfu.publishDisabled(roomSlotCamera);
      final screen = await sfu.publishDisabled(
        roomSlotScreen,
        sourceId: 'screen_0',
      );
      expect(room.videoRequests, [
        (roomSlotCamera, null),
        (roomSlotScreen, 'screen_0'),
      ]);
      expect(room.published.every((m) => !m.enabled), isTrue);
      await sfu.senderCryptor(camera, 'acct_a/dev_a:1');
      await sfu.senderCryptor(screen, 'acct_a/dev_a:2');
      await camera.setEnabled(true);
      await screen.setEnabled(true);
      await microtasks();
      expect(sfu.poisoned, isFalse);
      expect(room.published.every((m) => m.enabled), isTrue);
    });

    test('screen audio has no capture and is refused', () async {
      await expectLater(
        sfu.publishDisabled(roomSlotScreenAudio),
        throwsUnsupportedError,
      );
    });

    test('a refused capture is reported, nothing is published', () async {
      room.denyVideo = true;
      await expectLater(
        sfu.publishDisabled(roomSlotCamera),
        throwsA(isA<SfuCaptureDenied>()),
      );
      expect(room.published, isEmpty);
      expect(sfu.poisoned, isFalse);
    });

    test('a reconnect disables the video as well as the voice', () async {
      await publishVoice();
      final camera = await sfu.publishDisabled(roomSlotCamera);
      await sfu.senderCryptor(camera, 'acct_a/dev_a:1');
      await camera.setEnabled(true);
      await microtasks();
      expect(room.published.every((m) => m.enabled), isTrue);
      room.deliver(const LiveKitReconnecting());
      await microtasks();
      expect(room.published.every((m) => !m.enabled), isTrue);
      expect(sfu.poisoned, isTrue);
      await expectLater(
        sfu.publishDisabled(roomSlotCamera),
        throwsStateError,
      );
    });

    test('a video publish with no cryptor of ours is caught like voice',
        () async {
      final camera = await sfu.publishDisabled(roomSlotCamera);
      // Never gets its cryptor; LiveKit republishes it on a new sender.
      room.republish(room.published.single);
      await microtasks();
      expect(sfu.poisoned, isTrue);
      await expectLater(camera.setEnabled(true), throwsStateError);
    });

    // The camera and screen publish options are fixed by the design's
    // fail-closed rules. Remove one and this fails.
    test('publish options: one layer, no backup codec, VP8', () {
      for (final options in [
        roomCameraPublishOptions,
        roomScreenPublishOptions,
      ]) {
        expect(options.simulcast, isFalse, reason: 'S1 first (one IV space)');
        expect(
          options.backupVideoCodec.enabled,
          isFalse,
          reason: 'a backup codec is a second sender with no cryptor',
        );
        expect(options.videoCodec, 'vp8');
      }
    });
  });
}
