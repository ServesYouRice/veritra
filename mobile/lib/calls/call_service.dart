import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/models.dart';
import '../crypto/crypto_service.dart';
import 'call_media.dart';

/// Call lifecycle states after which no transition is accepted. Matches
/// `isTerminalCallState` in server/internal/storage/content_store.go.
bool isTerminalCallState(String state) =>
    state == 'rejected' || state == 'missed' || state == 'ended';

/// Whether an ICE server entry (`urls` as one string or a list, as the
/// server's /api/v1/calls/config returns) names a turn: or turns: URL.
bool _hasTurnUrl(Map<String, Object?> server) {
  final urls = server['urls'];
  final list = urls is String
      ? <Object?>[urls]
      : urls is List
          ? urls
          : null;
  return list != null &&
      list.any((url) =>
          url is String &&
          (url.toLowerCase().startsWith('turn:') ||
              url.toLowerCase().startsWith('turns:')));
}

/// The relay-only candidate filter (D56), defence in depth behind
/// `iceTransportPolicy: relay`. Returns [candidate] only if its `typ` is
/// `relay`, with the related address (raddr/rport, which for a relay
/// candidate is this device's public address as the TURN server saw it)
/// replaced by the unspecified address, as libwebrtc itself does under a
/// relay-only policy. Anything that cannot be parsed is dropped.
@visibleForTesting
String? relayCandidateOnly(String candidate) {
  final body = candidate.startsWith('a=') ? candidate.substring(2) : candidate;
  if (!body.startsWith('candidate:')) return null;
  // Any whitespace separates tokens, and keywords match in any case, so
  // `raddr  1.2.3.4` or `RADDR` cannot slip past.
  final tokens = candidate.trim().split(RegExp(r'\s+'));
  final keys = tokens.map((token) => token.toLowerCase()).toList();
  final typ = keys.indexOf('typ');
  if (typ < 0 || typ + 1 >= keys.length || keys[typ + 1] != 'relay') {
    return null;
  }
  // Every token is checked, not key/value pairs, so a malformed extension
  // cannot shift the pairing and let the related address through.
  for (var i = typ + 2; i < tokens.length; i++) {
    if (keys[i] == 'raddr' || keys[i] == 'rport') {
      if (i + 1 >= tokens.length) return null;
      tokens[i + 1] = keys[i] == 'rport'
          ? '0'
          : tokens[i + 1].contains(':')
              ? '::'
              : '0.0.0.0';
      i++;
    }
  }
  return tokens.join(' ');
}

/// A transition was abandoned because the server's current session no longer
/// allows it, for example the call ended while this device was answering.
class CallUnavailableException implements Exception {
  const CallUnavailableException(this.callId, this.state);
  final String callId;

  /// The server's current state for the call.
  final String state;

  @override
  String toString() => 'CallUnavailableException: call is $state';
}

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

  /// Set when the call is being torn down; queued sends then do nothing.
  bool _ending = false;

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
  /// [filter], when set, rewrites each local candidate before it is
  /// signalled, or returns null to drop it.
  void listen({String? Function(String candidate)? filter}) {
    peer.onIceCandidate = (candidate) {
      final raw = candidate.candidate;
      // A null or empty candidate marks the end of gathering; not signalled.
      if (_released || raw == null || raw.isEmpty) return;
      final value = filter == null ? raw : filter(raw);
      if (value == null) return;
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
    // close() only stops the connection; dispose() frees the native peer
    // and its event channel.
    await _quietly(peer.dispose);
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
      CallMediaFactory? media,
      Future<void> Function(Duration delay)? retryDelay,
      this.allowDirectConnections = false})
      : media = media ?? const FlutterWebRtcMediaFactory(),
        _retryDelay = retryDelay ?? Future<void>.delayed {
    _subscription = incoming.listen(_onIncoming,
        onError: (Object error) => _reportError(null, error));
  }

  /// How many times one transition is retried after a stale-version
  /// rejection. Both peers write the same per-call version (each ICE
  /// candidate, the answer, hang-up), so overlapping writes are expected.
  static const int maxConflictRetries = 5;

  /// Calls relay through TURN by default (D56): ICE gathers only relay
  /// candidates and only those are signalled, so the other side never
  /// learns this device's addresses. When true (a user setting that warns
  /// that the other side then sees their address), direct paths are allowed.
  final bool allowDirectConnections;

  final Future<void> Function(Duration delay) _retryDelay;
  final Random _jitter = Random();

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

  /// Latest session of calls being hung up whose 'ended' transition has not
  /// succeeded yet, so end(callId) can retry.
  final Map<String, CallSession> _terminating = <String, CallSession>{};
  final Map<String, Future<void>> _endings = <String, Future<void>>{};

  /// Ids of calls that reached a terminal state, newest last, so late
  /// signals for them are dropped instead of re-buffered. Bounded.
  final LinkedHashSet<String> _terminated = LinkedHashSet<String>();
  static const int maxRecentlyTerminated = 256;

  /// A call held here ended remotely (hung up, rejected, missed): its media
  /// is already released. Not emitted for a hang-up started with end().
  Stream<({String callId, String state})> get terminations =>
      _terminations.stream;
  final StreamController<({String callId, String state})> _terminations =
      StreamController<({String callId, String state})>.broadcast();

  @visibleForTesting
  List<String> get pendingCallIds => List<String>.unmodifiable(
      <String>{..._pendingSessions.keys, ..._earlySignals.keys});

  @visibleForTesting
  int get recentlyTerminatedCount => _terminated.length;
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
    CallSession? created;
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
      final call = created =
          await api.createCall(token, conversationId, encrypted.metadata);
      active = _activate(call, media);
    } catch (_) {
      await media.release();
      if (created != null) unawaited(_abandon(created));
      rethrow;
    }
    try {
      await _finishSetup(active);
    } catch (_) {
      unawaited(_abandon(active.session));
      rethrow;
    }
    return active;
  }

  /// Best-effort 'ended' for a call created here that setup gave up on, so
  /// the other side does not ring until the server expires it. Never throws.
  Future<void> _abandon(CallSession call) async {
    if (_terminated.contains(call.id)) return;
    var latest = call;
    try {
      await _transition(() => latest, (session) => latest = session,
          state: (_) => 'ended',
          giveUp: (current) => isTerminalCallState(current.state));
    } catch (_) {
      // Best effort: the server expires the ringing call eventually.
    }
    _markTerminated(call.id);
  }

  Future<ActiveCall> answer(
      CallSession call, Map<String, Object?> offer) async {
    if (offer['kind'] != 'offer' ||
        offer['sdp'] is! String ||
        offer['sdp_type'] is! String) {
      throw const FormatException('invalid encrypted call offer');
    }
    // Already over: do not turn on the microphone or camera for it.
    if (_isOver(call.id)) {
      throw CallUnavailableException(call.id, 'ended');
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
      final updated = await _transition(
          () => _newest(_pendingSessions[call.id], call), _recordPending,
          state: (_) => 'active',
          metadata: encrypted.metadata,
          giveUp: (current) =>
              current.state != 'ringing' || _isOver(current.id));
      active = _activate(updated, media);
    } catch (_) {
      await media.release();
      rethrow;
    }
    await _finishSetup(active);
    return active;
  }

  /// Declines a ringing call. The latest known session is kept until the
  /// server accepts the rejection, so a failed reject can be retried.
  Future<void> reject(CallSession call) async {
    if (_terminated.contains(call.id)) return;
    try {
      await _transition(
          () => _newest(_pendingSessions[call.id], call), _recordPending,
          state: (_) => 'rejected',
          giveUp: (current) => current.state != 'ringing');
    } on CallUnavailableException catch (error) {
      // Already over (the caller hung up): nothing left to reject.
      if (!isTerminalCallState(error.state)) rethrow;
    }
    _markTerminated(call.id);
  }

  /// Hangs up. Local media stops at once, whatever the server answers. The
  /// 'ended' transition runs after any send already in flight for the call,
  /// on the newest known version, and queued sends not yet started are
  /// dropped. If it fails, the call's latest session is kept, so calling
  /// end(callId) again retries without an [expectedVersion]. A call the
  /// server already shows as over counts as ended.
  Future<void> end(String callId, {int? expectedVersion}) {
    final running = _endings[callId];
    if (running != null) return running;
    final ending = _end(callId, expectedVersion)
        // A block body: returning the removed future would await itself.
        .whenComplete(() {
      _endings.remove(callId);
    });
    _endings[callId] = ending;
    return ending;
  }

  Future<void> _end(String callId, int? expectedVersion) async {
    final active = _calls.remove(callId);
    final pending = _pendingSessions.remove(callId);
    _earlySignals.remove(callId);
    if (active != null) {
      active._ending = true;
      _recordTerminating(_newest(pending, active.session));
      await active._media.release();
      try {
        await active.enqueueSend(() => _sendEnded(
            callId, () => _newest(_terminating[callId], active.session)));
      } finally {
        await _closeCall(active);
      }
      return;
    }
    // Already over (ended remotely, or an earlier end() got through).
    if (_terminated.contains(callId)) return;
    if (pending != null) _recordTerminating(pending);
    final known = _terminating[callId];
    if (expectedVersion == null && known != null) {
      await _sendEnded(callId, () => _terminating[callId] ?? known);
      return;
    }
    if (expectedVersion == null) {
      throw StateError(
          'Cannot end unknown call session $callId without an explicit expectedVersion');
    }
    // The caller vouches for the version; without a session there is no
    // conversation to refresh from, so this is a single attempt.
    await api.transitionCall(token, callId, 'ended',
        expectedVersion: expectedVersion);
    _markTerminated(callId);
  }

  Future<void> _sendEnded(String callId, CallSession Function() latest) async {
    try {
      await _transition(latest, _recordTerminating,
          state: (_) => 'ended',
          giveUp: (current) => isTerminalCallState(current.state));
    } on CallUnavailableException {
      // The server already shows the call as over.
    }
    _markTerminated(callId);
  }

  /// Forgets every pending trace of [callId] and remembers it as over, so
  /// late signals for it are dropped.
  void _markTerminated(String callId) {
    _pendingSessions.remove(callId);
    _earlySignals.remove(callId);
    _terminating.remove(callId);
    _terminated.remove(callId);
    _terminated.add(callId);
    while (_terminated.length > maxRecentlyTerminated) {
      _terminated.remove(_terminated.first);
    }
  }

  /// Handles a session in a terminal state, inside the inbound lane. Its
  /// signal is not applied: the server keeps the previous metadata on a
  /// terminal transition, so it may be a replayed answer or candidate.
  Future<void> _handleTerminal(CallSession session) async {
    final callId = session.id;
    final active = _calls.remove(callId);
    final wasPending = _pendingSessions.containsKey(callId) ||
        _earlySignals.containsKey(callId);
    _markTerminated(callId);
    if (active != null) {
      _adopt(active, session);
      active._ending = true;
      await active._media.release();
      // Not awaited: a stuck request must not stall inbound handling for
      // every call. Streams close once the queued work has finished.
      unawaited(active._outbound.then((_) => _closeCall(active)));
    }
    if ((active != null || wasPending) && !_terminations.isClosed) {
      _terminations.add((callId: callId, state: session.state));
    }
  }

  void _recordTerminating(CallSession session) {
    final known = _terminating[session.id];
    if (known == null || session.version > known.version) {
      _terminating[session.id] = session;
    }
  }

  /// Wraps fully set-up [media] in an [ActiveCall] and registers it. Runs
  /// synchronously, so nothing can observe a half-registered call.
  ActiveCall _activate(CallSession call, _CallMedia media) {
    if (_disposed) throw StateError('Call service was disposed during setup');
    if (_isOver(call.id)) {
      // Ended by the other side, or hung up here, before setup finished.
      throw CallUnavailableException(call.id, 'ended');
    }
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
    if (!iceServers.any(_hasTurnUrl)) {
      // No server details here: they would carry TURN credentials.
      throw StateError(
          'Calls need a self-hosted TURN service, and none is configured');
    }
    final relayOnly = !allowDirectConnections;
    final peer = await media.createPeer(<String, Object?>{
      'iceServers': iceServers,
      'iceTransportPolicy': relayOnly ? 'relay' : 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    // Handlers go on before any description is set: gathering starts at
    // setLocalDescription, tracks arrive during setRemoteDescription, and
    // flutter_webrtc drops events while no handler is set.
    final call = _CallMedia(peer)
      ..listen(filter: relayOnly ? relayCandidateOnly : null);
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
    // Hung up after this send was queued: the call is over, skip it.
    if (active._ending) return;
    final encrypted =
        await crypto.encryptCallSignal(active.session.conversationId, signal);
    final CallSession updated;
    try {
      updated = await _transition(
          () => active.session, (session) => _adopt(active, session),
          // A same-state write: after a refresh the state may have moved on
          // (ringing -> active), and the server allows no step back.
          state: (current) => current.state,
          metadata: encrypted.metadata,
          // Stop retrying once hung up, so 'ended' is not held back.
          giveUp: (current) =>
              active._ending || isTerminalCallState(current.state));
    } on CallUnavailableException {
      if (active._ending) return;
      rethrow;
    }
    _adopt(active, updated);
  }

  /// Sets [active]'s session only if [session] is newer. Send responses and
  /// pushed sessions race, and the version must never go back.
  bool _adopt(ActiveCall active, CallSession session) {
    if (session.version <= active.session.version) return false;
    active.session = session;
    return true;
  }

  /// Records [session] for a call with no [ActiveCall] yet, if newer.
  /// Whether [callId] is over or being hung up here.
  bool _isOver(String callId) =>
      _terminated.contains(callId) ||
      _terminating.containsKey(callId) ||
      _endings.containsKey(callId);

  void _recordPending(CallSession session) {
    // A call that is over must not come back as pending.
    if (_isOver(session.id)) return;
    final known = _pendingSessions[session.id];
    if (known == null || session.version > known.version) {
      _pendingSessions[session.id] = session;
    }
  }

  static CallSession _newest(CallSession? a, CallSession b) =>
      a != null && a.version > b.version ? a : b;

  /// Sends one transition on the newest known session. When the server
  /// rejects it as stale ('call_version_conflict': the other peer wrote
  /// first), refreshes the session, passes it to [adopt] and retries, at most
  /// [maxConflictRetries] times. Other errors are not retried.
  ///
  /// [state] picks the target state from the session about to be used.
  /// Before each attempt, [giveUp] can stop the transition; it then throws
  /// [CallUnavailableException].
  ///
  /// Retries resend the same encrypted [metadata]. That is safe: the server
  /// checks the version before it writes anything, so a rejected attempt
  /// stored nothing and the peer never saw that ciphertext.
  Future<CallSession> _transition(
      CallSession Function() latest, void Function(CallSession) adopt,
      {required String Function(CallSession current) state,
      Map<String, Object?>? metadata,
      required bool Function(CallSession current) giveUp}) async {
    for (var attempt = 0;; attempt++) {
      final current = latest();
      if (giveUp(current)) {
        throw CallUnavailableException(current.id, current.state);
      }
      try {
        return await api.transitionCall(token, current.id, state(current),
            expectedVersion: current.version, encryptedMetadata: metadata);
      } on ApiException catch (error) {
        if (error.serverCode != 'call_version_conflict' ||
            attempt >= maxConflictRetries) {
          rethrow;
        }
        await _retryDelay(
            Duration(milliseconds: 50 * (attempt + 1) + _jitter.nextInt(100)));
        final refreshed = (await api.calls(token, current.conversationId))
            .where((call) => call.id == current.id)
            .firstOrNull;
        // Not listed any more (pruned or out of the newest 100): give up.
        if (refreshed == null) rethrow;
        adopt(refreshed);
      }
    }
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
    final callId = incoming.call.id;
    if (isTerminalCallState(incoming.call.state)) {
      await _handleTerminal(incoming.call);
      return;
    }
    // A late signal for a call that is already over.
    if (_terminated.contains(callId)) return;
    if (_terminating.containsKey(callId)) {
      // Being hung up here: keep the newest version for a retried end(),
      // and apply nothing to the released peer.
      _recordTerminating(incoming.call);
      return;
    }
    final active = _calls[callId];
    // Until its drain has run, a new call's signals queue behind the early
    // ones so they are applied in arrival order.
    if (active == null || !active._drained) {
      _recordPending(incoming.call);
      (_earlySignals[incoming.call.id] ??= <Map<String, Object?>>[])
          .add(incoming.signal);
      if (active == null && incoming.signal['kind'] == 'offer') {
        _incomingOffers.add(incoming);
      }
      return;
    }
    _adopt(active, incoming.call);
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
        // A session pushed while setup awaited the server can be newer than
        // the one setup returned.
        final pending = _pendingSessions.remove(callId);
        if (pending != null) _adopt(active, pending);
        active._drained = true;
        for (final signal
            in _earlySignals.remove(callId) ?? const <Map<String, Object?>>[]) {
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

  /// Stops [call]'s queued sends and releases its media, then closes its
  /// streams.
  Future<void> _disposeCall(ActiveCall call) async {
    call._ending = true;
    await call._media.release();
    await _closeCall(call);
  }

  Future<void> _closeCall(ActiveCall call) async {
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
    _terminating.clear();
    _terminated.clear();
    await _incomingOffers.close();
    await _terminations.close();
    await _errors.close();
  }
}
