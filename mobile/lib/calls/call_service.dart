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
      required this.remoteStreams});
  CallSession session;
  final RTCPeerConnection peerConnection;
  final MediaStream localStream;
  final StreamController<MediaStream> remoteStreams;
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
        remoteStreams: StreamController<MediaStream>.broadcast());
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
    final updated = await api.transitionCall(token, call.id, 'active',
        encryptedMetadata: encrypted.metadata);
    final active = ActiveCall(
        session: updated,
        peerConnection: connection.peerConnection,
        localStream: connection.localStream,
        remoteStreams: StreamController<MediaStream>.broadcast());
    _installCallbacks(active);
    _calls[call.id] = active;
    await _drainEarly(call.id);
    return active;
  }

  Future<void> reject(String callId) =>
      api.transitionCall(token, callId, 'rejected');

  Future<void> end(String callId) async {
    final active = _calls.remove(callId);
    try {
      await api.transitionCall(token, callId, 'ended');
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
      unawaited(_sendSignal(active, <String, Object?>{
        'kind': 'ice',
        'candidate': candidate.candidate,
        'sdp_mid': candidate.sdpMid,
        'sdp_mline_index': candidate.sdpMLineIndex,
      }));
    };
  }

  Future<void> _sendSignal(
      ActiveCall active, Map<String, Object?> signal) async {
    final encrypted =
        await crypto.encryptCallSignal(active.session.conversationId, signal);
    await api.transitionCall(token, active.session.id, active.session.state,
        encryptedMetadata: encrypted.metadata);
  }

  Future<void> _handleIncoming(IncomingCallSignal incoming) async {
    final active = _calls[incoming.call.id];
    if (active == null) {
      (_earlySignals[incoming.call.id] ??= <Map<String, Object?>>[])
          .add(incoming.signal);
      if (incoming.signal['kind'] == 'offer') _incomingOffers.add(incoming);
      return;
    }
    active.session = incoming.call;
    await _applySignal(active, incoming.signal);
  }

  Future<void> _drainEarly(String callId) async {
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
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    for (final call in _calls.values.toList()) {
      await _disposeCall(call);
    }
    _calls.clear();
    _earlySignals.clear();
    await _incomingOffers.close();
  }
}
