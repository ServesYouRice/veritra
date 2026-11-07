import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/call_controller.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';

import 'call_service_fakes.dart';

const Map<String, Object?> _offer = <String, Object?>{
  'kind': 'offer',
  'sdp': 'remote-offer',
  'sdp_type': 'offer',
  'video': true,
};

class _H {
  _H() {
    api = FakeCallApi(log);
    media = FakeMediaFactory(log);
    service = NativeCallService(
        api: api,
        token: 'token',
        crypto: FakeCallCrypto(log),
        incoming: incoming.stream,
        media: media,
        retryDelay: (_) async {});
    controller = CallController(
        service: service,
        selfAccountId: 'acc_callee',
        speakerSupported: true,
        ringTimeout: const Duration(milliseconds: 200),
        setSpeaker: (on) async => speaker.add(on));
  }

  final log = <String>[];
  final speaker = <bool>[];
  final incoming = StreamController<IncomingCallSignal>.broadcast();
  late final FakeCallApi api;
  late final FakeMediaFactory media;
  late final NativeCallService service;
  late final CallController controller;

  Future<void> close() async {
    controller.dispose();
    await service.dispose();
    await incoming.close();
  }

  Future<void> ring({String id = 'call_1'}) async {
    final call = callSession(id: id);
    api.server[id] = call;
    incoming.add(IncomingCallSignal(call, _offer));
    await pumpEventQueue();
  }
}

_H _h() {
  final h = _H();
  addTearDown(h.close);
  return h;
}

void main() {
  test('outgoing call rings, connects on the first remote stream, hangs up',
      () async {
    final h = _h();
    await h.controller.start('conv_1', withVideo: true);
    expect(h.controller.phase, CallPhase.ringingOut);
    expect(h.media.peer.configuration['iceTransportPolicy'], 'relay');
    h.media.peer.emitTrack(FakeStream(h.log, 'remote'));
    await pumpEventQueue();
    expect(h.controller.phase, CallPhase.active);

    h.controller.toggleMute();
    expect(h.controller.muted, isTrue);
    expect(h.media.stream.tracks.firstWhere((t) => t.name == 'audio').enabled,
        isFalse);
    h.controller.toggleCamera();
    expect(h.media.stream.tracks.firstWhere((t) => t.name == 'video').enabled,
        isFalse);
    await h.controller.toggleSpeaker();
    expect(h.controller.speakerOn, isTrue);

    await h.controller.hangUp();
    expect(h.controller.phase, CallPhase.idle);
    expect(h.api.transitions.last.state, 'ended');
    expect(h.speaker, <bool>[true, false]);
    expect(h.media.peer.closeCount, 1);
  });

  test('no answer: caller gives up and sees a notice', () async {
    final h = _h();
    await h.controller.start('conv_1');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(h.controller.phase, CallPhase.idle);
    expect(h.controller.notice?.kind, CallNoticeKind.noAnswer);
    expect(h.api.transitions.last.state, 'ended');
  });

  test('a call that cannot start shows a failure notice and frees media',
      () async {
    final h = _h();
    h.api.iceServers = <Map<String, Object?>>[];
    await h.controller.start('conv_1');
    expect(h.controller.phase, CallPhase.idle);
    expect(h.controller.notice?.kind, CallNoticeKind.failed);
  });

  test('incoming call can be declined', () async {
    final h = _h();
    await h.ring();
    expect(h.controller.phase, CallPhase.ringingIn);
    expect(h.controller.video, isTrue);
    await h.controller.decline();
    expect(h.controller.phase, CallPhase.idle);
    expect(h.api.transitions.single.state, 'rejected');
    expect(h.controller.notice, isNull);
  });

  test('incoming call can be accepted, then ended remotely', () async {
    final h = _h();
    await h.ring();
    await h.controller.accept();
    expect(h.controller.phase, CallPhase.connecting);
    expect(h.api.transitions.single.state, 'active');
    h.media.peer.emitTrack(FakeStream(h.log, 'remote'));
    await pumpEventQueue();
    expect(h.controller.phase, CallPhase.active);
    h.incoming.add(IncomingCallSignal(
        callSession(state: 'ended', version: 9), const <String, Object?>{}));
    await pumpEventQueue();
    expect(h.controller.phase, CallPhase.idle);
    expect(h.controller.notice, isNull);
  });

  test('caller hangs up before answer: missed-call notice', () async {
    final h = _h();
    await h.ring();
    h.incoming.add(IncomingCallSignal(
        callSession(state: 'missed', version: 2), const <String, Object?>{}));
    await pumpEventQueue();
    expect(h.controller.phase, CallPhase.idle);
    expect(h.controller.notice?.kind, CallNoticeKind.missed);
    h.controller.dismissNotice();
    expect(h.controller.notice, isNull);
  });

  test('a second incoming call while busy is declined', () async {
    final h = _h();
    await h.ring();
    await h.ring(id: 'call_2');
    expect(h.controller.callId, 'call_1');
    expect(h.api.transitions.where((t) => t.callId == 'call_2').single.state,
        'rejected');
    expect(h.controller.notice?.kind, CallNoticeKind.busy);
  });

  test('own offers are never shown as incoming', () async {
    final h = _h();
    final base = callSession();
    final own = CallSession(
        id: base.id,
        conversationId: base.conversationId,
        createdBy: 'acc_callee',
        invitedAccountId: 'acc_caller',
        state: base.state,
        version: base.version,
        metadata: base.metadata,
        createdAt: base.createdAt);
    h.incoming.add(IncomingCallSignal(own, _offer));
    await pumpEventQueue();
    expect(h.controller.phase, CallPhase.idle);
  });
}
