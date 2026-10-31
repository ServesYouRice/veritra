import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
