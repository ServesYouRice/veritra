import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/models.dart';
import '../crypto/crypto_service.dart';

class ActiveCall {
  ActiveCall(
      {required this.session,
      required this.peerConnection,
      required this.localStream,
      required this.remoteStreams,
      required this.signalErrors});
  CallSession session;
  final RTCPeerConnection peerConnection;
  final MediaStream localStream;
  final StreamController<MediaStream> remoteStreams;

  /// Outbound signalling failures. Trickle ICE is sent in the background, so
  /// without this its errors would be unobservable unhandled async errors.
  final StreamController<Object> signalErrors;

  /// Serializes outbound transitions. Every send carries the optimistic
  /// concurrency token [CallSession.version], so two in-flight sends would
  /// read the same version and all but the first would be rejected as stale.
  Future<void> _outbound = Future<void>.value();

  Future<void> enqueueSend(Future<void> Function() send) {
    final queued = _outbound.then((_) => send());
    _outbound = queued.catchError((Object _) {});
    return queued;
  }
}

/// Native WebRTC transport. Signaling is always an MLS application payload;
/// the server sees only call lifecycle metadata and ciphertext.
class NativeCallService {
  NativeCallService(
      {required this.api,
      required this.token,
      required this.crypto,
      required Stream<IncomingCallSignal> incoming}) {
    _subscription = incoming.listen(_handleIncoming);
  }

  final ApiClient api;
  final String token;
  final MlsConversationCryptoService crypto;
  final Map<String, ActiveCall> _calls = <String, ActiveCall>{};
  final Map<String, List<Map<String, Object?>>> _earlySignals =
      <String, List<Map<String, Object?>>>{};

  /// Latest session seen for a call that has no [ActiveCall] yet. The caller
  /// keeps signalling while the callee decides, so the session that arrived
  /// with the offer is stale by the time answer/reject is sent.
  final Map<String, CallSession> _pendingSessions = <String, CallSession>{};
  final StreamController<IncomingCallSignal> _incomingOffers =
      StreamController<IncomingCallSignal>.broadcast();
  Stream<IncomingCallSignal> get incomingOffers => _incomingOffers.stream;
  StreamSubscription<IncomingCallSignal>? _subscription;

  Future<ActiveCall> start(String conversationId, {bool video = false}) async {
    final connection = await _createConnection(video: video);
    final offer =
        await connection.peerConnection.createOffer(<String, Object?>{});
    await connection.peerConnection.setLocalDescription(offer);
    final encrypted = await crypto.encryptCallSignal(
        conversationId, <String, Object?>{
      'kind': 'offer',
      'sdp': offer.sdp,
      'sdp_type': offer.type,
      'video': video
    });
    final call =
        await api.createCall(token, conversationId, encrypted.metadata);
    final active = ActiveCall(
        session: call,
        peerConnection: connection.peerConnection,
        localStream: connection.localStream,
        remoteStreams: StreamController<MediaStream>.broadcast(),
        signalErrors: StreamController<Object>.broadcast());
    _installCallbacks(active);
    _calls[call.id] = active;
    await _drainEarly(call.id);
    return active;
  }

  Future<ActiveCall> answer(
      CallSession call, Map<String, Object?> offer) async {
    if (offer['kind'] != 'offer' ||
        offer['sdp'] is! String ||
        offer['sdp_type'] is! String) {
      throw const FormatException('invalid encrypted call offer');
    }
    final connection = await _createConnection(video: offer['video'] == true);
    await connection.peerConnection.setRemoteDescription(RTCSessionDescription(
        offer['sdp'] as String, offer['sdp_type'] as String));
    final answer =
        await connection.peerConnection.createAnswer(<String, Object?>{});
    await connection.peerConnection.setLocalDescription(answer);
    final encrypted = await crypto.encryptCallSignal(
        call.conversationId, <String, Object?>{
      'kind': 'answer',
      'sdp': answer.sdp,
      'sdp_type': answer.type
    });
    final current = _pendingSessions[call.id] ?? call;
    final updated = await api.transitionCall(token, call.id, 'active',
        expectedVersion: current.version,
        encryptedMetadata: encrypted.metadata);
    final active = ActiveCall(
        session: updated,
        peerConnection: connection.peerConnection,
        localStream: connection.localStream,
        remoteStreams: StreamController<MediaStream>.broadcast(),
        signalErrors: StreamController<Object>.broadcast());
    _installCallbacks(active);
    _calls[call.id] = active;
    await _drainEarly(call.id);
    return active;
  }

  Future<void> reject(CallSession call) async {
    final current = _pendingSessions.remove(call.id) ?? call;
    _earlySignals.remove(call.id);
    await api.transitionCall(token, call.id, 'rejected',
        expectedVersion: current.version);
  }

  Future<void> end(String callId, {int? expectedVersion}) async {
    final active = _calls.remove(callId);
    final pending = _pendingSessions.remove(callId);
    _earlySignals.remove(callId);
    final version =
        expectedVersion ?? active?.session.version ?? pending?.version;
    if (version == null) {
      throw StateError(
          'Cannot end unknown call session $callId without an explicit expectedVersion');
    }
    try {
      await api.transitionCall(token, callId, 'ended',
          expectedVersion: version);
    } finally {
      if (active != null) await _disposeCall(active);
    }
  }

  Future<({RTCPeerConnection peerConnection, MediaStream localStream})>
      _createConnection({required bool video}) async {
    final iceServers = await api.callIceServers(token);
    if (iceServers.isEmpty) {
      throw StateError('A self-hosted TURN service is required for calls');
    }
    final peer = await createPeerConnection(<String, Object?>{
      'iceServers': iceServers,
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    final stream = await navigator.mediaDevices.getUserMedia(<String, Object?>{
      'audio': <String, Object?>{
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true
      },
      'video': video,
    });
    for (final track in stream.getTracks()) {
      await peer.addTrack(track, stream);
    }
    return (peerConnection: peer, localStream: stream);
  }

  void _installCallbacks(ActiveCall active) {
    active.peerConnection.onTrack = (event) {
      for (final stream in event.streams) {
        active.remoteStreams.add(stream);
      }
    };
    active.peerConnection.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _queueSignal(active, <String, Object?>{
        'kind': 'ice',
        'candidate': candidate.candidate,
        'sdp_mid': candidate.sdpMid,
        'sdp_mline_index': candidate.sdpMLineIndex,
      });
    };
  }

  /// Queues an outbound signal. ICE candidates arrive from the native layer in
  /// bursts, so serializing keeps every send on a fresh version token instead
  /// of racing and losing all but one candidate to a stale-version rejection.
  void _queueSignal(ActiveCall active, Map<String, Object?> signal) {
    final sent = active.enqueueSend(() => _sendSignal(active, signal));
    unawaited(sent.catchError((Object error) {
      if (!active.signalErrors.isClosed) active.signalErrors.add(error);
    }));
  }

  Future<void> _sendSignal(
      ActiveCall active, Map<String, Object?> signal) async {
    final encrypted =
        await crypto.encryptCallSignal(active.session.conversationId, signal);
    final updated = await api.transitionCall(
        token, active.session.id, active.session.state,
        expectedVersion: active.session.version,
        encryptedMetadata: encrypted.metadata);
    active.session = updated;
  }

  Future<void> _handleIncoming(IncomingCallSignal incoming) async {
    final active = _calls[incoming.call.id];
    if (active == null) {
      _pendingSessions[incoming.call.id] = incoming.call;
      (_earlySignals[incoming.call.id] ??= <Map<String, Object?>>[])
          .add(incoming.signal);
      if (incoming.signal['kind'] == 'offer') _incomingOffers.add(incoming);
      return;
    }
    active.session = incoming.call;
    await _applySignal(active, incoming.signal);
  }

  Future<void> _drainEarly(String callId) async {
    _pendingSessions.remove(callId);
    final active = _calls[callId];
    if (active == null) return;
    for (final signal
        in _earlySignals.remove(callId) ?? const <Map<String, Object?>>[]) {
      await _applySignal(active, signal);
    }
  }

  Future<void> _applySignal(
      ActiveCall active, Map<String, Object?> signal) async {
    switch (signal['kind']) {
      case 'answer':
        if (signal['sdp'] is! String || signal['sdp_type'] is! String) {
          throw const FormatException('invalid encrypted call answer');
        }
        await active.peerConnection.setRemoteDescription(RTCSessionDescription(
            signal['sdp'] as String, signal['sdp_type'] as String));
        break;
      case 'ice':
        final candidate = signal['candidate'];
        if (candidate is! String)
          throw const FormatException('invalid encrypted ICE candidate');
        await active.peerConnection.addCandidate(RTCIceCandidate(
            candidate,
            signal['sdp_mid'] as String?,
            (signal['sdp_mline_index'] as num?)?.toInt()));
        break;
    }
  }

  Future<void> _disposeCall(ActiveCall call) async {
    for (final track in call.localStream.getTracks()) {
      await track.stop();
    }
    await call.localStream.dispose();
    await call.peerConnection.close();
    await call.remoteStreams.close();
    await call.signalErrors.close();
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    for (final call in _calls.values.toList()) {
      await _disposeCall(call);
    }
    _calls.clear();
    _earlySignals.clear();
    _pendingSessions.clear();
    await _incomingOffers.close();
  }
}
