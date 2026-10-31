import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/core/app_state.dart';

import 'call_service_fakes.dart';

const Map<String, Object?> _offer = <String, Object?>{
  'kind': 'offer',
  'sdp': 'remote-offer',
  'sdp_type': 'offer',
};

class _Harness {
  _Harness() {
    api = FakeCallApi(log);
    crypto = FakeCallCrypto(log);
    media = FakeMediaFactory(log);
    service = NativeCallService(
      api: api,
      token: 'token',
      crypto: crypto,
      incoming: incoming.stream,
      media: media,
    );
  }

  final List<String> log = <String>[];
  final StreamController<IncomingCallSignal> incoming =
      StreamController<IncomingCallSignal>();
  late final FakeCallApi api;
  late final FakeCallCrypto crypto;
  late final FakeMediaFactory media;
  late final NativeCallService service;

  Future<void> close() async {
    await service.dispose();
    await incoming.close();
  }
}

_Harness _harness() {
  final harness = _Harness();
  addTearDown(harness.close);
  return harness;
}

/// Asserts every acquired resource was released exactly once.
void _expectReleasedOnce(FakeMediaFactory media, {required bool hadStream}) {
  expect(media.peer.closeCount, 1, reason: 'peer closed once');
  if (hadStream) {
    expect(media.stream.disposeCount, 1, reason: 'stream disposed once');
    for (final track in media.stream.tracks) {
      expect(track.stopCount, 1, reason: 'track ${track.name} stopped once');
    }
  } else {
    expect(media.streams, isEmpty);
  }
}

void main() {
  _task016();
  group('TASK-015 setup failure releases media', () {
    const startSteps = <String>[
      'getUserMedia',
      'addTrack',
      'createOffer',
      'setLocalDescription',
      'encryptCallSignal',
      'createCall',
    ];
    for (final step in startSteps) {
      test('start() releases everything when $step fails', () async {
        final h = _harness();
        final failure = InjectedFailure(step);
        _inject(h, step, failure);

        await expectLater(
            h.service.start('conv_1', video: true), throwsA(same(failure)));

        _expectReleasedOnce(h.media, hadStream: step != 'getUserMedia');
        expect(h.service.activeCallIds, isEmpty);
        await expectLater(h.service.end('call_1'), throwsStateError);
      });
    }

    const answerSteps = <String>[
      'getUserMedia',
      'addTrack',
      'setRemoteDescription',
      'createAnswer',
      'setLocalDescription',
      'encryptCallSignal',
      'transitionCall',
    ];
    for (final step in answerSteps) {
      test('answer() releases everything when $step fails', () async {
        final h = _harness();
        final failure = InjectedFailure(step);
        _inject(h, step, failure);

        await expectLater(
            h.service.answer(callSession(), _offer), throwsA(same(failure)));

        _expectReleasedOnce(h.media, hadStream: step != 'getUserMedia');
        expect(h.service.activeCallIds, isEmpty);
      });
    }

    test('a cleanup error does not replace the setup error', () async {
      final h = _harness();
      final failure = InjectedFailure('createCall');
      h.api.failures['createCall'] = failure;
      h.media.configurePeer = (peer) => peer.failures['close'] = 'unused';

      await expectLater(h.service.start('conv_1'), throwsA(same(failure)));
      expect(h.media.peer.closeCount, 1);
    });

    test('success keeps media running until end()', () async {
      final h = _harness();
      final call = await h.service.start('conv_1');
      expect(h.media.peer.closeCount, 0);
      expect(h.media.stream.disposeCount, 0);
      expect(h.service.activeCallIds, <String>[call.session.id]);

      await h.service.end(call.session.id);
      _expectReleasedOnce(h.media, hadStream: true);
    });

    test('createPeer failure acquires nothing', () async {
      final h = _harness();
      final failure = InjectedFailure('createPeer');
      h.media.failures['createPeer'] = failure;
      await expectLater(h.service.start('conv_1'), throwsA(same(failure)));
      expect(h.media.peers, isEmpty);
      expect(h.media.streams, isEmpty);
    });
  });
}

/// Lets queued microtasks and zero-delay timers run.
Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _relay(int n) =>
    'candidate:$n 1 udp 41885439 203.0.113.$n 5000$n typ relay '
    'raddr 0.0.0.0 rport 0';

List<String?> _sentCandidates(FakeCallApi api) => api.transitions
    .where((t) => t.signal?['kind'] == 'ice')
    .map((t) => t.signal!['candidate'] as String?)
    .toList();

void _task016() {
  group('TASK-016 early ICE candidates and remote tracks', () {
    test('start() signals candidates gathered before the call exists',
        () async {
      final h = _harness();
      h.media.configurePeer = (peer) {
        peer.duringSetLocal = (p) => p.emitCandidate(_relay(1));
      };
      h.api.createGate = () async {
        h.media.peer.emitCandidate(_relay(2));
        h.media.peer.emitCandidate(null);
      };

      await h.service.start('conv_1');
      h.media.peer.emitCandidate(_relay(3));
      await _settle();

      expect(_sentCandidates(h.api), <String>[_relay(1), _relay(2), _relay(3)]);
      expect(h.api.transitions.map((t) => t.expectedVersion), <int>[1, 2, 3]);
    });

    test('answer() signals candidates gathered during the transition',
        () async {
      final h = _harness();
      h.media.configurePeer = (peer) {
        peer.duringSetLocal = (p) => p.emitCandidate(_relay(1));
      };
      var gated = false;
      h.api.transitionGate = (request) async {
        if (gated) return;
        gated = true;
        h.media.peer.emitCandidate(_relay(2));
      };

      await h.service.answer(callSession(), _offer);
      h.media.peer.emitCandidate(_relay(3));
      await _settle();

      expect(h.api.transitions.first.state, 'active');
      expect(_sentCandidates(h.api), <String>[_relay(1), _relay(2), _relay(3)]);
    });

    test('answer() replays a remote track fired during setRemoteDescription',
        () async {
      final h = _harness();
      final remote = FakeStream(h.log, 'remote');
      h.media.configurePeer = (peer) {
        peer.duringSetRemote = (p) {
          p.emitTrack(remote);
          p.emitTrack(remote);
        };
      };

      final call = await h.service.answer(callSession(), _offer);
      await _settle();

      expect(call.currentRemoteStreams, <Object>[remote]);
      expect(await call.remoteStreams.first, same(remote));
    });

    test('start() replays a remote track from a drained buffered answer',
        () async {
      final h = _harness();
      final remote = FakeStream(h.log, 'remote');
      h.media.configurePeer = (peer) {
        peer.duringSetRemote = (p) => p.emitTrack(remote);
      };
      h.api.createGate = () async {
        h.incoming.add(IncomingCallSignal(
            callSession(version: 2),
            const <String, Object?>{
              'kind': 'answer',
              'sdp': 'remote-answer',
              'sdp_type': 'answer',
            }));
        await _settle();
      };

      final call = await h.service.start('conv_1');
      expect(h.media.peer.remoteDescriptions, hasLength(1));
      expect(await call.remoteStreams.first, same(remote));

      final later = FakeStream(h.log, 'later');
      final seen = <MediaStream>[];
      final sub = call.remoteStreams.listen(seen.add);
      h.media.peer.emitTrack(later);
      await _settle();
      await sub.cancel();
      expect(seen, <Object>[remote, later]);
    });

    test('candidates from a failed setup are never sent', () async {
      final h = _harness();
      final failure = InjectedFailure('createCall');
      h.media.configurePeer = (peer) {
        peer.duringSetLocal = (p) => p.emitCandidate(_relay(1));
      };
      h.api.failures['createCall'] = failure;
      await expectLater(h.service.start('conv_1'), throwsA(same(failure)));
      h.media.peer.emitCandidate(_relay(2));
      await _settle();
      expect(h.api.transitions, isEmpty);
    });
  });
}

void _inject(_Harness h, String step, Object failure) {
  switch (step) {
    case 'getUserMedia':
      h.media.failures[step] = failure;
    case 'encryptCallSignal':
      h.crypto.failure = failure;
    case 'createCall':
    case 'transitionCall':
      h.api.failures[step] = failure;
    default:
      h.media.peerFailures[step] = failure;
  }
}
