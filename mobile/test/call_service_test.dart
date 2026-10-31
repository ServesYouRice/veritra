import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/core/api_client.dart';
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
      retryDelay: (delay) async => delays.add(delay),
    );
  }

  final List<Duration> delays = <Duration>[];

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
  _task017();
  _task018();
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

Map<String, Object?> _ice(Object? candidate,
        {Object? sdpMid = '0', Object? index = 0}) =>
    <String, Object?>{
      'kind': 'ice',
      'candidate': candidate,
      'sdp_mid': sdpMid,
      'sdp_mline_index': index,
    };

const Map<String, Object?> _answer = <String, Object?>{
  'kind': 'answer',
  'sdp': 'remote-answer',
  'sdp_type': 'answer',
};

void _task017() {
  group('TASK-017 serialized inbound signals', () {
    test('an ice signal waits for the preceding answer', () async {
      final h = _harness();
      final call = await h.service.start('conv_1');
      final gate = Completer<void>();
      h.media.peer.setRemoteGate = gate;

      h.incoming.add(IncomingCallSignal(call.session, _answer));
      h.incoming.add(IncomingCallSignal(call.session, _ice('remote-1')));
      await _settle();
      expect(h.log, isNot(contains('peer.addCandidate:remote-1')));

      gate.complete();
      await _settle();
      final done = h.log.indexOf('peer.setRemoteDescription:done');
      final added = h.log.indexOf('peer.addCandidate:remote-1');
      expect(done, isNonNegative);
      expect(added, greaterThan(done));
    });

    test('signals arriving during the drain wait behind it', () async {
      final h = _harness();
      final gate = Completer<void>();
      h.media.configurePeer = (peer) => peer.setRemoteGate = gate;
      h.api.createGate = () async {
        h.incoming.add(IncomingCallSignal(callSession(), _answer));
        await _settle();
      };

      final started = h.service.start('conv_1');
      while (!h.log.contains('peer.setRemoteDescription:start')) {
        await Future<void>.delayed(Duration.zero);
      }
      h.incoming.add(IncomingCallSignal(callSession(), _ice('remote-1')));
      await _settle();
      expect(h.log, isNot(contains('peer.addCandidate:remote-1')));
      gate.complete();
      await started;
      await _settle();
      expect(h.log.indexOf('peer.addCandidate:remote-1'),
          greaterThan(h.log.indexOf('peer.setRemoteDescription:done')));
    });

    test('bad and failing signals are reported, not thrown', () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final h = _harness();
        final call = await h.service.start('conv_1');
        final errors = <Object>[];
        call.signalErrors.stream.listen(errors.add);

        h.incoming.add(IncomingCallSignal(call.session, _ice('a', sdpMid: 5)));
        h.incoming.add(IncomingCallSignal(call.session, _ice('b', index: 'x')));
        h.incoming.add(IncomingCallSignal(call.session, _ice(7)));
        h.incoming.add(IncomingCallSignal(call.session,
            const <String, Object?>{'kind': 'answer', 'sdp': 1}));
        await _settle();
        h.media.peer.failures['addCandidate'] = InjectedFailure('addCandidate');
        h.incoming.add(IncomingCallSignal(call.session, _ice('c')));
        await _settle();
        h.media.peer.failures.remove('addCandidate');
        h.incoming.add(IncomingCallSignal(call.session, _ice('d')));
        await _settle();

        expect(errors, hasLength(5));
        expect(errors.take(4), everyElement(isA<FormatException>()));
        expect(errors.last, isA<InjectedFailure>());
        expect(h.media.peer.addedCandidates.map((c) => c.candidate),
            <String>['d']);
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty);
    });

    test('errors on the incoming stream reach the service error stream',
        () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final h = _harness();
        final errors = <Object>[];
        h.service.errors.listen(errors.add);
        final failure = InjectedFailure('incoming');
        h.incoming.addError(failure);
        await _settle();
        expect(errors, <Object>[failure]);
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty);
    });

    test('dispose() during setup drops the call and releases media',
        () async {
      final h = _harness();
      final created = Completer<void>();
      h.api.createGate = () => created.future;
      final started = h.service.start('conv_1');
      await _settle();
      final disposed = h.service.dispose();
      created.complete();
      await expectLater(started, throwsStateError);
      await disposed;
      expect(h.media.peer.closeCount, 1);
      expect(h.media.stream.disposeCount, 1);
    });
  });
}

void _task018() {
  group('TASK-018 session adoption and version-conflict retry', () {
    test('a stale send response does not undo a newer push', () async {
      final h = _harness();
      final call = await h.service.start('conv_1');
      final released = Completer<void>();
      h.api.onTransition = (request) async {
        await released.future;
        return callSession(state: 'ringing', version: 2);
      };
      h.media.peer.emitCandidate(_relay(1));
      await _settle();
      h.incoming.add(IncomingCallSignal(
          callSession(state: 'active', version: 3), _ice('remote-1')));
      await _settle();
      expect(call.session.version, 3);
      released.complete();
      await _settle();
      expect(call.session.version, 3);
      expect(call.session.state, 'active');
    });

    test('a session pushed during answer() is adopted after the drain',
        () async {
      final h = _harness();
      var pushed = false;
      h.api.transitionGate = (request) async {
        if (pushed) return;
        pushed = true;
        h.incoming.add(IncomingCallSignal(
            callSession(state: 'active', version: 3), _ice('remote-1')));
        await _settle();
      };
      final call = await h.service.answer(callSession(), _offer);
      expect(h.api.transitions.first.expectedVersion, 1);
      expect(call.session.version, 3);
      expect(h.media.peer.addedCandidates, hasLength(1));
    });

    test('an ICE send retries once on a version conflict', () async {
      final h = _harness();
      final call = await h.service.start('conv_1');
      final errors = <Object>[];
      call.signalErrors.stream.listen(errors.add);
      // The callee wrote meanwhile: the server is one version ahead.
      h.api.server['call_1'] = callSession(state: 'active', version: 2);

      h.media.peer.emitCandidate(_relay(1));
      await _settle();

      expect(errors, isEmpty);
      final ice = h.api.transitions;
      expect(ice.map((t) => '${t.state}@${t.expectedVersion}'),
          <String>['ringing@1', 'active@2']);
      expect(identical(ice[0].metadata, ice[1].metadata), isTrue,
          reason: 'the same ciphertext is resent');
      expect(h.crypto.encrypted.where((s) => s['kind'] == 'ice'), hasLength(1));
      expect(call.session.version, 3);
      expect(h.api.callsRequests, 1);
      expect(h.delays, hasLength(1));
    });

    test('persistent conflicts stop at the bound and are reported',
        () async {
      final h = _harness();
      final call = await h.service.start('conv_1');
      final errors = <Object>[];
      call.signalErrors.stream.listen(errors.add);
      h.api.onTransition = (request) async => throw versionConflict();

      h.media.peer.emitCandidate(_relay(1));
      await _settle();

      expect(h.api.transitions,
          hasLength(NativeCallService.maxConflictRetries + 1));
      expect(errors, hasLength(1));
      expect((errors.single as ApiException).serverCode,
          'call_version_conflict');
    });

    test('other API errors are not retried', () async {
      final h = _harness();
      final call = await h.service.start('conv_1');
      final errors = <Object>[];
      call.signalErrors.stream.listen(errors.add);
      h.api.onTransition = (request) async => throw ApiException(503);

      h.media.peer.emitCandidate(_relay(1));
      await _settle();

      expect(h.api.transitions, hasLength(1));
      expect(h.api.callsRequests, 0);
      expect(errors, hasLength(1));
    });

    test('a terminal refreshed session stops ICE retries', () async {
      final h = _harness();
      final call = await h.service.start('conv_1');
      final errors = <Object>[];
      call.signalErrors.stream.listen(errors.add);
      h.api.server['call_1'] = callSession(state: 'rejected', version: 2);

      h.media.peer.emitCandidate(_relay(1));
      await _settle();

      expect(h.api.transitions, hasLength(1));
      expect(errors.single, isA<CallUnavailableException>());
    });

    test('answer() retries with the refreshed version', () async {
      final h = _harness();
      h.api.server['call_1'] = callSession(version: 2);
      final call = await h.service.answer(callSession(version: 1), _offer);
      expect(h.api.transitions.map((t) => '${t.state}@${t.expectedVersion}'),
          <String>['active@1', 'active@2']);
      expect(call.session.version, 3);
    });

    test('answer() stops and releases media when the call is gone',
        () async {
      final h = _harness();
      h.api.server['call_1'] = callSession(state: 'ended', version: 2);
      await expectLater(h.service.answer(callSession(version: 1), _offer),
          throwsA(isA<CallUnavailableException>()));
      expect(h.api.transitions, hasLength(1));
      _expectReleasedOnce(h.media, hadStream: true);
    });

    test('reject() retries with the refreshed version', () async {
      final h = _harness();
      h.api.server['call_1'] = callSession(version: 3);
      await h.service.reject(callSession(version: 1));
      expect(h.api.transitions.map((t) => '${t.state}@${t.expectedVersion}'),
          <String>['rejected@1', 'rejected@3']);
    });

    test('reject() keeps the latest session until it succeeds', () async {
      final h = _harness();
      final offer = h.service.incomingOffers.first;
      h.incoming.add(IncomingCallSignal(callSession(version: 2), _offer));
      await offer;
      h.api.server['call_1'] = callSession(version: 2);
      final failure = InjectedFailure('network');
      h.api.failures['transitionCall'] = failure;
      await expectLater(
          h.service.reject(callSession(version: 1)), throwsA(same(failure)));

      h.api.failures.clear();
      await h.service.reject(callSession(version: 1));
      expect(h.api.transitions.last.expectedVersion, 2);
      expect(h.api.callsRequests, 0);
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
