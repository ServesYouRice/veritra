import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:private_messenger/calls/call_media.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';

/// Fakes for NativeCallService tests. Every fake records into one shared
/// [log] so tests can assert the order of native and network calls.

class InjectedFailure implements Exception {
  InjectedFailure(this.step);
  final String step;
  @override
  String toString() => 'InjectedFailure($step)';
}

class FakeTrack implements MediaStreamTrack {
  FakeTrack(this.log, this.name);
  final List<String> log;
  final String name;
  int stopCount = 0;

  @override
  String? get id => name;

  @override
  Future<void> stop() async {
    stopCount++;
    log.add('track.stop:$name');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeStream extends MediaStream {
  FakeStream(this.log, String id, {this.tracks = const <FakeTrack>[]})
      : super(id, 'local');
  final List<String> log;
  final List<FakeTrack> tracks;
  int disposeCount = 0;

  @override
  bool? get active => true;

  @override
  List<MediaStreamTrack> getTracks() => List<MediaStreamTrack>.of(tracks);

  @override
  Future<void> dispose() async {
    disposeCount++;
    log.add('stream.dispose:$id');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakePeer implements RTCPeerConnection {
  FakePeer(this.log, this.configuration);
  final List<String> log;
  final Map<String, Object?> configuration;

  /// Step name -> error to throw from that method.
  final Map<String, Object> failures = <String, Object>{};

  /// Runs inside setLocalDescription / setRemoteDescription, before they
  /// complete, to model native events fired during negotiation.
  void Function(FakePeer peer)? duringSetLocal;
  void Function(FakePeer peer)? duringSetRemote;

  /// When set, setRemoteDescription waits for it.
  Completer<void>? setRemoteGate;

  int closeCount = 0;
  int disposeCount = 0;
  final List<RTCIceCandidate> addedCandidates = <RTCIceCandidate>[];
  final List<RTCSessionDescription> remoteDescriptions =
      <RTCSessionDescription>[];

  @override
  Function(RTCIceCandidate candidate)? onIceCandidate;
  @override
  Function(RTCTrackEvent event)? onTrack;

  void _maybeFail(String step) {
    final failure = failures[step];
    if (failure != null) throw failure;
  }

  void emitCandidate(String? candidate,
          {String? sdpMid = '0', int? sdpMLineIndex = 0}) =>
      onIceCandidate?.call(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));

  void emitTrack(MediaStream stream) => onTrack?.call(RTCTrackEvent(
      streams: <MediaStream>[stream], track: FakeTrack(log, 'remote')));

  @override
  Future<RTCSessionDescription> createOffer(
      [Map<String, dynamic>? constraints]) async {
    log.add('peer.createOffer');
    _maybeFail('createOffer');
    return RTCSessionDescription('offer-sdp', 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer(
      [Map<String, dynamic>? constraints]) async {
    log.add('peer.createAnswer');
    _maybeFail('createAnswer');
    return RTCSessionDescription('answer-sdp', 'answer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    log.add('peer.setLocalDescription');
    _maybeFail('setLocalDescription');
    duringSetLocal?.call(this);
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    log.add('peer.setRemoteDescription:start');
    _maybeFail('setRemoteDescription');
    duringSetRemote?.call(this);
    final gate = setRemoteGate;
    if (gate != null) await gate.future;
    remoteDescriptions.add(description);
    log.add('peer.setRemoteDescription:done');
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    log.add('peer.addCandidate:${candidate.candidate}');
    _maybeFail('addCandidate');
    addedCandidates.add(candidate);
  }

  @override
  Future<RTCRtpSender> addTrack(MediaStreamTrack track,
      [MediaStream? stream]) async {
    log.add('peer.addTrack');
    _maybeFail('addTrack');
    return _FakeSender();
  }

  @override
  Future<void> close() async {
    closeCount++;
    log.add('peer.close');
    _maybeFail('close');
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    log.add('peer.dispose');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSender implements RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeMediaFactory implements CallMediaFactory {
  FakeMediaFactory(this.log);
  final List<String> log;
  final List<FakePeer> peers = <FakePeer>[];
  final List<FakeStream> streams = <FakeStream>[];
  final Map<String, Object> failures = <String, Object>{};

  /// Applied to each new peer before it is returned.
  void Function(FakePeer peer)? configurePeer;

  /// Failures to install on each new peer.
  final Map<String, Object> peerFailures = <String, Object>{};

  FakePeer get peer => peers.single;
  FakeStream get stream => streams.single;

  @override
  Future<RTCPeerConnection> createPeer(
      Map<String, Object?> configuration) async {
    log.add('media.createPeer');
    final failure = failures['createPeer'];
    if (failure != null) throw failure;
    final peer = FakePeer(log, configuration)..failures.addAll(peerFailures);
    configurePeer?.call(peer);
    peers.add(peer);
    return peer;
  }

  @override
  Future<MediaStream> getUserMedia(Map<String, Object?> constraints) async {
    log.add('media.getUserMedia');
    final failure = failures['getUserMedia'];
    if (failure != null) throw failure;
    final stream = FakeStream(log, 'local${streams.length}', tracks: [
      FakeTrack(log, 'audio'),
      if (constraints['video'] == true) FakeTrack(log, 'video'),
    ]);
    streams.add(stream);
    return stream;
  }
}

class FakeCallCrypto implements MlsConversationCryptoService {
  FakeCallCrypto(this.log);
  final List<String> log;
  final List<Map<String, Object?>> encrypted = <Map<String, Object?>>[];
  Object? failure;

  @override
  Future<EncryptedCallSignal> encryptCallSignal(
      String conversationId, Map<String, Object?> signal) async {
    log.add('crypto.encrypt:${signal['kind']}');
    final error = failure;
    if (error != null) throw error;
    encrypted.add(signal);
    return EncryptedCallSignal(<String, Object?>{
      'version': 1,
      'ciphertext': 'ct${encrypted.length}',
      'signal': signal,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One recorded transitionCall request.
class TransitionRequest {
  TransitionRequest(this.callId, this.state, this.expectedVersion,
      this.metadata);
  final String callId;
  final String state;
  final int expectedVersion;
  final Map<String, Object?>? metadata;

  Map<String, Object?>? get signal =>
      metadata?['signal'] as Map<String, Object?>?;
}

CallSession callSession({
  String id = 'call_1',
  String conversationId = 'conv_1',
  String state = 'ringing',
  int version = 1,
}) =>
    CallSession(
      id: id,
      conversationId: conversationId,
      createdBy: 'acc_caller',
      invitedAccountId: 'acc_callee',
      state: state,
      version: version,
      metadata: const <String, Object?>{},
      createdAt: DateTime.utc(2026, 10, 31),
    );

class FakeCallApi implements ApiClient {
  FakeCallApi(this.log);
  final List<String> log;

  List<Map<String, Object?>> iceServers = <Map<String, Object?>>[
    <String, Object?>{
      'urls': <String>['turn:turn.example.test:3478'],
      'username': 'u',
      'credential': 'c',
    }
  ];

  final Map<String, Object> failures = <String, Object>{};
  final List<TransitionRequest> transitions = <TransitionRequest>[];
  final List<Map<String, Object?>> created = <Map<String, Object?>>[];

  /// Server-side truth: the current session per call id.
  final Map<String, CallSession> server = <String, CallSession>{};
  int callsRequests = 0;

  /// When set, createCall / transitionCall wait for the returned future.
  Future<void> Function()? createGate;
  Future<void> Function(TransitionRequest request)? transitionGate;

  /// Override for transitionCall; default applies optimistic concurrency
  /// against [server].
  Future<CallSession> Function(TransitionRequest request)? onTransition;

  void _maybeFail(String step) {
    final failure = failures[step];
    if (failure != null) throw failure;
  }

  @override
  Future<List<Map<String, Object?>>> callIceServers(String token) async {
    log.add('api.callIceServers');
    _maybeFail('callIceServers');
    return iceServers;
  }

  @override
  Future<CallSession> createCall(String token, String conversationId,
      Map<String, Object?> encryptedMetadata) async {
    log.add('api.createCall');
    created.add(encryptedMetadata);
    final gate = createGate;
    if (gate != null) await gate();
    _maybeFail('createCall');
    final call = callSession(conversationId: conversationId, version: 1);
    server[call.id] = call;
    return call;
  }

  @override
  Future<CallSession> transitionCall(
    String token,
    String callId,
    String state, {
    required int expectedVersion,
    Map<String, Object?>? encryptedMetadata,
  }) async {
    final request =
        TransitionRequest(callId, state, expectedVersion, encryptedMetadata);
    log.add('api.transitionCall:$state@$expectedVersion');
    transitions.add(request);
    final gate = transitionGate;
    if (gate != null) await gate(request);
    _maybeFail('transitionCall');
    final handler = onTransition;
    if (handler != null) return handler(request);
    final current = server[callId] ??
        callSession(id: callId, state: 'ringing', version: expectedVersion);
    if (current.version != expectedVersion) {
      throw versionConflict();
    }
    final next = callSession(
        id: callId,
        conversationId: current.conversationId,
        state: state,
        version: current.version + 1);
    server[callId] = next;
    return next;
  }

  @override
  Future<List<CallSession>> calls(String token, String conversationId) async {
    log.add('api.calls');
    callsRequests++;
    _maybeFail('calls');
    return server.values
        .where((call) => call.conversationId == conversationId)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ApiException versionConflict() =>
    ApiException(409, '{"error":"call_version_conflict"}');
