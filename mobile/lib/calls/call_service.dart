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
      required this.signalErrors})
      : _media = media;
  CallSession session;
  final _CallMedia _media;
  RTCPeerConnection get peerConnection => _media.peer;
  MediaStream get localStream => _media.stream!;

  /// Remote streams received so far, in arrival order.
  List<MediaStream> get currentRemoteStreams =>
      List<MediaStream>.unmodifiable(_media.remoteStreams);

  /// Every remote stream: first those already received, then new ones as
  /// they arrive. Tracks often arrive during setRemoteDescription, before
  /// start()/answer() returns, so a plain broadcast stream would lose them.
  Stream<MediaStream> get remoteStreams =>
      Stream<MediaStream>.multi((controller) {
        for (final stream in _media.remoteStreams) {
          controller.add(stream);
        }
        if (_remoteUpdates.isClosed) {
          controller.close();
          return;
        }
        final updates = _remoteUpdates.stream
            .listen(controller.add, onDone: controller.close);
        controller.onCancel = updates.cancel;
      });
  final StreamController<MediaStream> _remoteUpdates =
      StreamController<MediaStream>.broadcast(sync: true);

  /// Outbound signalling failures. Trickle ICE is sent in the background, so
  /// without this its errors would be unobservable unhandled async errors.
  final StreamController<Object> signalErrors;

  /// Serializes outbound transitions. Every send carries the optimistic
  /// concurrency token [CallSession.version], so two in-flight sends would
  /// read the same version and all but the first would be rejected as stale.
  Future<void> _outbound = Future<void>.value();

  /// False until the signals that arrived before this call existed have
  /// been applied; later signals wait behind them.
  bool _drained = false;

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

  /// Remote streams, de-duplicated by id (one per stream, not per track).
  final List<MediaStream> remoteStreams = <MediaStream>[];

  /// Local candidates gathered before the call session exists, in order.
  final List<Map<String, Object?>> _pendingCandidates =
      <Map<String, Object?>>[];
  void Function(Map<String, Object?> signal)? _onCandidate;
  void Function(MediaStream stream)? _onRemoteStream;

  bool get released => _released;

  /// Installs the peer's ICE and track handlers. Until [attach] runs, local
  /// candidates are buffered and remote streams only recorded.
  void listen() {
    peer.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      // A null or empty candidate marks the end of gathering; not signalled.
      if (_released || value == null || value.isEmpty) return;
      final signal = <String, Object?>{
        'kind': 'ice',
        'candidate': value,
        'sdp_mid': candidate.sdpMid,
        'sdp_mline_index': candidate.sdpMLineIndex,
      };
      final sink = _onCandidate;
      if (sink == null) {
        _pendingCandidates.add(signal);
      } else {
        sink(signal);
      }
    };
    peer.onTrack = (event) {
      if (_released) return;
      for (final stream in event.streams) {
        if (remoteStreams.any((known) => known.id == stream.id)) continue;
        remoteStreams.add(stream);
        _onRemoteStream?.call(stream);
      }
    };
  }

  /// Connects this media to its call: flushes buffered candidates in order
  /// to [onCandidate], then routes later events directly.
  void attach(
      {required void Function(Map<String, Object?> signal) onCandidate,
      required void Function(MediaStream stream) onRemoteStream}) {
    for (final signal in _pendingCandidates) {
      onCandidate(signal);
    }
    _pendingCandidates.clear();
    _onCandidate = onCandidate;
    _onRemoteStream = onRemoteStream;
  }

  /// Stops every local track, disposes the stream and closes the peer. Each
  /// step runs even if an earlier one fails, and cleanup errors are dropped
  /// so they never replace the error that caused the cleanup.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _pendingCandidates.clear();
    _onCandidate = null;
    _onRemoteStream = null;
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
    _subscription = incoming.listen(_onIncoming,
        onError: (Object error) => _reportError(null, error));
  }

  /// Serial lane for inbound work; see [_inLane].
  Future<void> _inbound = Future<void>.value();
  bool _disposed = false;

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

  /// Inbound failures that belong to no active call: errors on the incoming
  /// signal stream, or a failed signal for a call no longer held here.
  /// Errors for an active call go to its [ActiveCall.signalErrors].
  Stream<Object> get errors => _errors.stream;
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

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
    await _finishSetup(active);
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
    await _finishSetup(active);
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
    if (_disposed) throw StateError('Call service was disposed during setup');
    final active = ActiveCall._(
        session: call,
        media: media,
        signalErrors: StreamController<Object>.broadcast());
    _calls[call.id] = active;
    media.attach(
        onCandidate: (signal) => _queueSignal(active, signal),
        onRemoteStream: active._remoteUpdates.add);
    return active;
  }

  /// Drains early signals for a just-registered call. If the call cannot be
  /// handed out (the service was disposed meanwhile), it is unregistered and
  /// its media released before the error propagates.
  Future<void> _finishSetup(ActiveCall active) async {
    try {
      await _drainEarly(active);
    } catch (_) {
      if (identical(_calls[active.session.id], active)) {
        _calls.remove(active.session.id);
      }
      await _disposeCall(active);
      rethrow;
    }
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
    // Handlers go on before any description is set: gathering starts at
    // setLocalDescription, tracks arrive during setRemoteDescription, and
    // flutter_webrtc drops events while no handler is set.
    final call = _CallMedia(peer)..listen();
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

  /// Runs [work] after every inbound step queued before it. Incoming signals
  /// and the drain at the end of start()/answer() share this one lane, so
  /// signals are applied strictly in arrival order (an 'ice' never reaches
  /// addCandidate while the preceding 'answer' is still being applied).
  Future<T> _inLane<T>(Future<T> Function() work) {
    final result = _inbound.then((_) => work());
    _inbound = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _onIncoming(IncomingCallSignal incoming) {
    unawaited(_inLane(() => _processIncoming(incoming)));
  }

  /// One inbound step. Never throws: failures are reported instead, and the
  /// next signal is still processed.
  Future<void> _processIncoming(IncomingCallSignal incoming) async {
    if (_disposed) return;
    try {
      await _handleIncoming(incoming);
    } catch (error) {
      _reportError(_calls[incoming.call.id], error);
    }
  }

  void _reportError(ActiveCall? active, Object error) {
    if (active != null && !active.signalErrors.isClosed) {
      active.signalErrors.add(error);
    } else if (!_errors.isClosed) {
      _errors.add(error);
    }
  }

  Future<void> _handleIncoming(IncomingCallSignal incoming) async {
    final active = _calls[incoming.call.id];
    // Until its drain has run, a new call's signals queue behind the early
    // ones so they are applied in arrival order.
    if (active == null || !active._drained) {
      _pendingSessions[incoming.call.id] = incoming.call;
      (_earlySignals[incoming.call.id] ??= <Map<String, Object?>>[])
          .add(incoming.signal);
      if (active == null && incoming.signal['kind'] == 'offer') {
        _incomingOffers.add(incoming);
      }
      return;
    }
    active.session = incoming.call;
    await _applySignal(active, incoming.signal);
  }

  /// Applies the signals that arrived before [active] existed, inside the
  /// inbound lane. Throws when the service was disposed meanwhile, so
  /// start()/answer() never return a call whose media is already released.
  Future<void> _drainEarly(ActiveCall active) => _inLane(() async {
        final callId = active.session.id;
        if (_disposed || active._media.released) {
          throw StateError('Call $callId ended during setup');
        }
        _pendingSessions.remove(callId);
        active._drained = true;
        for (final signal in _earlySignals.remove(callId) ??
            const <Map<String, Object?>>[]) {
          if (_disposed || active._media.released) return;
          try {
            await _applySignal(active, signal);
          } catch (error) {
            _reportError(active, error);
          }
        }
      });

  Future<void> _applySignal(
      ActiveCall active, Map<String, Object?> signal) async {
    switch (signal['kind']) {
      case 'answer':
        final sdp = signal['sdp'];
        final type = signal['sdp_type'];
        if (sdp is! String || type is! String) {
          throw const FormatException('invalid encrypted call answer');
        }
        await active.peerConnection
            .setRemoteDescription(RTCSessionDescription(sdp, type));
        break;
      case 'ice':
        final candidate = signal['candidate'];
        final rawMid = signal['sdp_mid'];
        final rawIndex = signal['sdp_mline_index'];
        final sdpMid = rawMid is String ? rawMid : null;
        final index = rawIndex is int && rawIndex >= 0 ? rawIndex : null;
        if (candidate is! String ||
            (rawMid != null && sdpMid == null) ||
            (rawIndex != null && index == null)) {
          throw const FormatException('invalid encrypted ICE candidate');
        }
        await active.peerConnection
            .addCandidate(RTCIceCandidate(candidate, sdpMid, index));
        break;
    }
  }

  Future<void> _disposeCall(ActiveCall call) async {
    await call._media.release();
    await call._remoteUpdates.close();
    await call.signalErrors.close();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    // Steps not yet started see _disposed and do nothing; wait for the one
    // in flight so no inbound work runs against a released peer.
    await _inbound;
    for (final call in _calls.values.toList()) {
      await _disposeCall(call);
    }
    _calls.clear();
    _earlySignals.clear();
    _pendingSessions.clear();
    await _incomingOffers.close();
    await _errors.close();
  }
}
