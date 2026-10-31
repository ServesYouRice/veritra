import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/models.dart';
import '../crypto/crypto_service.dart';
import 'call_media.dart';

class ActiveCall {
  ActiveCall._(
      {required this.session,
      required _CallMedia media,
      required this.remoteStreams,
      required this.signalErrors})
      : _media = media;
  CallSession session;
  final _CallMedia _media;
  RTCPeerConnection get peerConnection => _media.peer;
  MediaStream get localStream => _media.stream!;
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

/// The native resources one call acquires: its peer connection and, once
/// getUserMedia succeeds, the local stream. [release] is idempotent, so setup
/// failure, hang-up, remote termination and service disposal can all call it.
class _CallMedia {
  _CallMedia(this.peer);
  final RTCPeerConnection peer;
  MediaStream? stream;
  bool _released = false;

  bool get released => _released;

  /// Stops every local track, disposes the stream and closes the peer. Each
  /// step runs even if an earlier one fails, and cleanup errors are dropped
  /// so they never replace the error that caused the cleanup.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    final local = stream;
    if (local != null) {
      for (final track in local.getTracks()) {
        await _quietly(track.stop);
      }
      await _quietly(local.dispose);
    }
    await _quietly(peer.close);
  }

  static Future<void> _quietly(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {}
  }
}

/// Native WebRTC transport. Signaling is always an MLS application payload;
/// the server sees only call lifecycle metadata and ciphertext.
class NativeCallService {
  NativeCallService(
      {required this.api,
      required this.token,
      required this.crypto,
      required Stream<IncomingCallSignal> incoming,
      CallMediaFactory? media})
      : media = media ?? const FlutterWebRtcMediaFactory() {
    _subscription = incoming.listen(_handleIncoming);
  }

  final ApiClient api;
  final String token;
  final MlsConversationCryptoService crypto;
  final CallMediaFactory media;
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

  /// Ids of calls this service currently holds media for.
  @visibleForTesting
  List<String> get activeCallIds => List<String>.unmodifiable(_calls.keys);
  StreamSubscription<IncomingCallSignal>? _subscription;

  Future<ActiveCall> start(String conversationId, {bool video = false}) async {
    final media = await _createConnection(video: video);
    final ActiveCall active;
    try {
      final offer = await media.peer.createOffer(<String, Object?>{});
      await media.peer.setLocalDescription(offer);
      final encrypted = await crypto.encryptCallSignal(
          conversationId, <String, Object?>{
        'kind': 'offer',
        'sdp': offer.sdp,
        'sdp_type': offer.type,
        'video': video
      });
      final call =
          await api.createCall(token, conversationId, encrypted.metadata);
      active = _activate(call, media);
    } catch (_) {
      await media.release();
      rethrow;
    }
    await _drainEarly(active.session.id);
    return active;
  }

  Future<ActiveCall> answer(
      CallSession call, Map<String, Object?> offer) async {
    if (offer['kind'] != 'offer' ||
        offer['sdp'] is! String ||
        offer['sdp_type'] is! String) {
      throw const FormatException('invalid encrypted call offer');
    }
    final media = await _createConnection(video: offer['video'] == true);
    final ActiveCall active;
    try {
      await media.peer.setRemoteDescription(RTCSessionDescription(
          offer['sdp'] as String, offer['sdp_type'] as String));
      final answer = await media.peer.createAnswer(<String, Object?>{});
      await media.peer.setLocalDescription(answer);
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
      active = _activate(updated, media);
    } catch (_) {
      await media.release();
      rethrow;
    }
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

  /// Wraps fully set-up [media] in an [ActiveCall] and registers it. Runs
  /// synchronously, so nothing can observe a half-registered call.
  ActiveCall _activate(CallSession call, _CallMedia media) {
    final active = ActiveCall._(
        session: call,
        media: media,
        remoteStreams: StreamController<MediaStream>.broadcast(),
        signalErrors: StreamController<Object>.broadcast());
    _installCallbacks(active);
    _calls[call.id] = active;
    return active;
  }

  /// Creates the peer connection and attaches local media. If any step after
  /// the peer exists fails, everything acquired so far is released before
  /// the error propagates.
  Future<_CallMedia> _createConnection({required bool video}) async {
    final iceServers = await api.callIceServers(token);
    if (iceServers.isEmpty) {
      throw StateError('A self-hosted TURN service is required for calls');
    }
    final peer = await media.createPeer(<String, Object?>{
      'iceServers': iceServers,
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    final call = _CallMedia(peer);
    try {
      final stream = call.stream = await media.getUserMedia(<String, Object?>{
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
    } catch (_) {
      await call.release();
      rethrow;
    }
    return call;
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
    await call._media.release();
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
