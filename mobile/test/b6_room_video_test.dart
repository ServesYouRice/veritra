import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/room_capture.dart';
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_media.dart';
import 'package:private_messenger/calls/room/room_ports.dart';

import 'b6_room_fakes.dart';
import 'b6_room_media_fakes.dart';

// B6 camera and screen share through the same fail-closed path as voice:
// published disabled, cryptor on and keyed, then enabled; bound on the
// receiving side only by the sender's sealed announcement.

class FakeCapture implements RoomCapture {
  FakeCapture({
    this.screen = true,
    this.needsSource = false,
    this.consent = true,
  });
  bool screen;
  bool needsSource;
  bool consent;
  Completer<bool>? consentGate;
  final List<String> log = [];

  @override
  bool get canUseCamera => true;
  @override
  bool get canShareScreen => screen;
  @override
  bool get screenNeedsSource => needsSource;
  @override
  Future<List<ScreenSource>> screenSources() async => const [
        ScreenSource(id: 'screen_0', name: 'Screen 1'),
      ];
  @override
  Future<bool> beginScreenShare() async {
    log.add('begin');
    final gate = consentGate;
    if (gate != null) return gate.future;
    return consent;
  }

  @override
  Future<void> endScreenShare() async => log.add('end');
}

void main() {
  late FakeServer server;
  late FakeClock clock;
  late FakeParent parent;
  late FakeHub hub;

  setUp(() {
    server = FakeServer('conv_1');
    clock = FakeClock();
    parent = FakeParent([member('a'), member('b'), member('c')]);
    hub = FakeHub();
  });

  Future<MediaDevice> start(
    String name, {
    RoomCapture capture = const NoRoomCapture(),
    int videoCap = roomVideoCap,
  }) async {
    final d = await MediaDevice.create(
      name,
      server,
      clock,
      parent,
      hub,
      capture: capture,
      videoCap: videoCap,
    );
    await d.engine.join('conv_1');
    await d.settle();
    return d;
  }

  Future<void> admit(
    MediaDevice existing,
    MediaDevice joiner, {
    List<MediaDevice> others = const [],
  }) async {
    existing.engine.refresh();
    await existing.settle();
    await clock.advance(const Duration(milliseconds: 250));
    await existing.settle();
    joiner.engine.refresh();
    await joiner.settle();
    for (final d in others) {
      d.engine.refresh();
      await d.settle();
    }
    for (final d in [existing, joiner, ...others]) {
      await d.settle();
    }
  }

  Future<void> end(List<MediaDevice> devices) async {
    for (final d in devices) {
      await d.media.close();
      d.engine.dispose();
    }
  }

  Future<(MediaDevice, MediaDevice)> pair({
    RoomCapture? captureA,
    int videoCap = roomVideoCap,
  }) async {
    final a = await start(
      'a',
      capture: captureA ?? FakeCapture(),
      videoCap: videoCap,
    );
    final b = await start('b', videoCap: videoCap);
    await admit(a, b);
    return (a, b);
  }

  group('camera', () {
    test(
      'is published disabled, encrypted and keyed, then enabled, then bound '
      'on the other side by its sender\'s announcement only',
      () async {
        final (a, b) = await pair();
        // A raw video track from the SFU that nobody announced: no tile.
        b.sfu.emit(
          SfuTrackSubscribed(
            FakeRemoteTrack('TR_stranger', 'sfu_a', isVideo: true),
          ),
        );
        await b.settle();
        expect(b.media.videoTiles, isEmpty);

        expect(a.media.canUseCamera, isTrue);
        await a.media.setCameraOn(true);
        await a.settle();
        await b.settle();

        final log = a.sfu.log;
        final publish = log.indexOf('publish 1');
        final cryptor = log.indexOf('sender cryptor acct_a/dev_a:1');
        final enabled = log.indexOf('cryptor acct_a/dev_a:1 enabled=true');
        final index = log.indexWhere(
          (l) => l.startsWith('cryptor acct_a/dev_a:1 index='),
        );
        final open = log.indexOf('track TR_sfu_a_1 enabled=true');
        expect(publish, greaterThanOrEqualTo(0));
        expect(cryptor, greaterThan(publish));
        expect(enabled, greaterThan(cryptor));
        expect(index, greaterThan(enabled));
        expect(open, greaterThan(index), reason: 'opens only once keyed');
        expect(a.provider.keys.containsKey('acct_a/dev_a:1@1'), isTrue);
        expect(a.media.cameraOn, isTrue);

        expect(b.media.boundTracks['TR_sfu_a_1'], 'acct_a/dev_a:1');
        final tile = b.media.videoTiles.single;
        expect(tile.memberId, 'acct_a/dev_a');
        expect(tile.slot, roomSlotCamera);
        expect(b.sfu.remote['TR_sfu_a_1']!.playing, isTrue);
        // The unannounced stranger is still not drawn.
        expect(b.media.videoTiles.map((t) => t.id),
            isNot(contains('TR_stranger')));
        // The sender sees its own preview.
        expect(a.media.videoTiles.single.local, isTrue);
        await end([a, b]);
      },
    );

    test('a cryptor that will not enable ends the call and stays dark',
        () async {
      final (a, b) = await pair();
      a.sfu.failSenderEnable = true;
      await a.media.setCameraOn(true);
      await a.settle();
      expect(a.engine.phase, RoomPhase.failed);
      expect(a.engine.failure, RoomFailure.cryptorNotFailClosed);
      expect(
        a.sfu.log.where((l) => l == 'track TR_sfu_a_1 enabled=true'),
        isEmpty,
      );
      await end([b]);
    });

    test('a refused camera shows a notice and the call goes on', () async {
      final (a, b) = await pair();
      a.sfu.denySlots.add(roomSlotCamera);
      await a.media.setCameraOn(true);
      await a.settle();
      expect(a.media.notice, RoomMediaNotice.cameraUnavailable);
      expect(a.media.cameraOn, isFalse);
      expect(a.media.requestingPermission, isFalse);
      expect(a.engine.phase, RoomPhase.active);
      expect(a.sfu.log.where((l) => l.contains('acct_a/dev_a:1')), isEmpty);
      a.media.dismissNotice();
      expect(a.media.notice, isNull);
      await end([a, b]);
    });

    test('is "requesting permission" while the OS may be asking', () async {
      final (a, b) = await pair();
      a.sfu.holdCapture = Completer<void>();
      final pending = a.media.setCameraOn(true);
      await pump();
      expect(a.media.requestingPermission, isTrue);
      a.sfu.holdCapture!.complete();
      await pending;
      await a.settle();
      expect(a.media.requestingPermission, isFalse);
      expect(a.media.cameraOn, isTrue);
      await end([a, b]);
    });

    test('off unpublishes it, disposes its cryptor and tells the room',
        () async {
      final (a, b) = await pair();
      await a.media.setCameraOn(true);
      await a.settle();
      await b.settle();
      expect(b.media.videoTiles, hasLength(1));
      await a.media.setCameraOn(false);
      await a.settle();
      await b.settle();
      expect(a.sfu.log, contains('unpublish TR_sfu_a_1'));
      expect(
        a.sfu.log.indexOf('cryptor acct_a/dev_a:1 disposed'),
        lessThan(a.sfu.log.indexOf('unpublish TR_sfu_a_1')),
      );
      expect(a.media.cameraOn, isFalse);
      expect(a.media.videoTiles, isEmpty);
      expect(b.media.videoTiles, isEmpty);
      expect(b.media.boundTracks.keys, isNot(contains('TR_sfu_a_1')));
      // The announcement no longer lists the track (the voice stays).
      expect(a.engine.phase, RoomPhase.active);
      await end([a, b]);
    });

    test('moves to the next epoch\'s key with the voice', () async {
      final (a, b) = await pair();
      await a.media.setCameraOn(true);
      await a.settle();
      final c = await start('c');
      await admit(a, c, others: [b]);
      String index(String l) => l.split('index=').last;
      final camera = a.sfu.log
          .where((l) => l.startsWith('cryptor acct_a/dev_a:1 index='))
          .map(index)
          .toList();
      final voice = a.sfu.log
          .where((l) => l.startsWith('cryptor acct_a/dev_a:0 index='))
          .map(index)
          .toList();
      expect(camera.toSet().length, greaterThan(1), reason: 'camera re-keyed');
      expect(
        camera.last,
        voice.last,
        reason: 'camera and voice end on the same epoch index',
      );
      await end([a, b, c]);
    });

    test('is independent of the mute', () async {
      final (a, b) = await pair();
      await a.media.setMicMuted(true);
      await a.media.setCameraOn(true);
      await a.settle();
      final voice = a.sfu.published.firstWhere((t) => t.slot == roomSlotVoice);
      final camera =
          a.sfu.published.firstWhere((t) => t.slot == roomSlotCamera);
      expect(voice.enabled, isFalse);
      expect(camera.enabled, isTrue);
      await end([a, b]);
    });
  });

  group('screen share', () {
    test(
      'asks the platform first, then publishes on the screen slot, bound on '
      'the other side',
      () async {
        final capture = FakeCapture(needsSource: true);
        final (a, b) = await pair(captureA: capture);
        expect(a.media.canShareScreen, isTrue);
        expect(a.media.screenNeedsSource, isTrue);
        await a.media.setSharingScreen(true, sourceId: 'screen_0');
        await a.settle();
        await b.settle();
        expect(capture.log, ['begin']);
        expect(a.sfu.lastSourceId, 'screen_0');
        expect(a.sfu.log, contains('sender cryptor acct_a/dev_a:2'));
        expect(a.media.sharingScreen, isTrue);
        expect(b.media.boundTracks['TR_sfu_a_2'], 'acct_a/dev_a:2');
        expect(b.media.videoTiles.single.slot, roomSlotScreen);
        // No preview of your own screen.
        expect(a.media.videoTiles, isEmpty);
        await a.media.setSharingScreen(false);
        await a.settle();
        expect(capture.log, ['begin', 'end']);
        expect(a.sfu.log, contains('unpublish TR_sfu_a_2'));
        expect(a.media.sharingScreen, isFalse);
        await end([a, b]);
      },
    );

    test('desktop needs a chosen source', () async {
      final capture = FakeCapture(needsSource: true);
      final (a, b) = await pair(captureA: capture);
      await a.media.setSharingScreen(true);
      expect(a.media.notice, RoomMediaNotice.screenNoSource);
      expect(capture.log, isEmpty);
      expect(a.sfu.log, isNot(contains('publish 2')));
      await end([a, b]);
    });

    test('a refused consent publishes nothing', () async {
      final capture = FakeCapture(consent: false);
      final (a, b) = await pair(captureA: capture);
      await a.media.setSharingScreen(true);
      await a.settle();
      expect(a.media.notice, RoomMediaNotice.screenUnavailable);
      expect(a.sfu.log, isNot(contains('publish 2')));
      expect(a.media.sharingScreen, isFalse);
      expect(capture.log, ['begin', 'end']);
      await end([a, b]);
    });

    test('a capture the platform refuses after the consent undoes it',
        () async {
      final capture = FakeCapture();
      final (a, b) = await pair(captureA: capture);
      a.sfu.denySlots.add(roomSlotScreen);
      await a.media.setSharingScreen(true);
      await a.settle();
      expect(a.media.notice, RoomMediaNotice.screenUnavailable);
      expect(capture.log, ['begin', 'end']);
      expect(a.engine.phase, RoomPhase.active);
      await end([a, b]);
    });

    test('the consent counts as a permission request', () async {
      final capture = FakeCapture()..consentGate = Completer<bool>();
      final (a, b) = await pair(captureA: capture);
      final pending = a.media.setSharingScreen(true);
      await pump();
      expect(a.media.requestingPermission, isTrue);
      capture.consentGate!.complete(true);
      await pending;
      await a.settle();
      expect(a.media.requestingPermission, isFalse);
      expect(a.media.sharingScreen, isTrue);
      await end([a, b]);
    });

    test('a share the system ends is unpublished and undone', () async {
      final capture = FakeCapture();
      final (a, b) = await pair(captureA: capture);
      await a.media.setSharingScreen(true);
      await a.settle();
      final track = a.sfu.published.firstWhere((t) => t.slot == roomSlotScreen);
      track.endedController.add(null);
      await a.settle();
      expect(a.media.sharingScreen, isFalse);
      expect(a.sfu.log, contains('unpublish TR_sfu_a_2'));
      expect(capture.log, ['begin', 'end']);
      await end([a, b]);
    });

    test('ending the call ends the share and the platform service', () async {
      final capture = FakeCapture();
      final (a, b) = await pair(captureA: capture);
      await a.media.setSharingScreen(true);
      await a.settle();
      await a.media.close();
      expect(capture.log, ['begin', 'end']);
      expect(a.sfu.log, contains('unpublish TR_sfu_a_2'));
      await end([b]);
    });

    test('a call that ends during the consent leaves nothing running',
        () async {
      final capture = FakeCapture()..consentGate = Completer<bool>();
      final (a, b) = await pair(captureA: capture);
      final pending = a.media.setSharingScreen(true);
      await pump();
      await a.media.close();
      capture.consentGate!.complete(true);
      await pending;
      expect(capture.log.last, 'end');
      expect(a.sfu.log, isNot(contains('publish 2')));
      await end([b]);
    });

    test('a platform that cannot share offers no control', () async {
      final (a, b) = await pair(captureA: FakeCapture(screen: false));
      expect(a.media.canShareScreen, isFalse);
      await a.media.setSharingScreen(true);
      expect(a.sfu.log, isNot(contains('publish 2')));
      await end([a, b]);
    });
  });

  group('room size (O3)', () {
    test('a room over the cap refuses camera and screen share', () async {
      final capture = FakeCapture();
      final (a, b) = await pair(captureA: capture, videoCap: 1);
      expect(a.engine.roster.length, 2);
      await a.media.setCameraOn(true);
      expect(a.media.notice, RoomMediaNotice.videoRoomFull);
      await a.media.setSharingScreen(true);
      expect(a.media.notice, RoomMediaNotice.videoRoomFull);
      expect(a.sfu.log, isNot(contains('publish 1')));
      expect(a.sfu.log, isNot(contains('publish 2')));
      expect(capture.log, isEmpty);
      await end([a, b]);
    });

    test('video stops when the room grows past the cap, voice stays', () async {
      final capture = FakeCapture();
      final a = await start('a', capture: capture, videoCap: 2);
      final b = await start('b', videoCap: 2);
      await admit(a, b);
      await a.media.setCameraOn(true);
      await a.media.setSharingScreen(true);
      await a.settle();
      expect(a.media.cameraOn, isTrue);
      final c = await start('c', videoCap: 2);
      await admit(a, c, others: [b]);
      await a.settle();
      expect(a.engine.roster.length, 3);
      expect(a.media.cameraOn, isFalse);
      expect(a.media.sharingScreen, isFalse);
      expect(a.media.notice, RoomMediaNotice.videoRoomFull);
      expect(capture.log.last, 'end');
      expect(a.sfu.published.single.slot, roomSlotVoice);
      expect(a.engine.phase, RoomPhase.active);
      await end([a, b, c]);
    });
  });
}
