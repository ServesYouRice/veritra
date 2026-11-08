import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/app_state.dart' show IncomingCallSignal;
import 'call_service.dart';

/// Where the one call this device may hold stands. Demo builds hold at most
/// one call at a time; a second incoming offer is declined as busy.
enum CallPhase { idle, ringingOut, ringingIn, connecting, active }

/// A short notice shown after a call ends without a conversation, or fails.
enum CallNoticeKind { missed, declined, noAnswer, failed, busy }

class CallNotice {
  const CallNotice(this.kind, this.conversationId);
  final CallNoticeKind kind;
  final String conversationId;
}

/// UI-facing state of one-to-one calls (B5). It owns no media itself: that
/// stays in [NativeCallService]. Calls relay through TURN by default (D56),
/// which the service enforces; nothing here can switch that off.
class CallController extends ChangeNotifier {
  CallController({
    required this.service,
    required this.selfAccountId,
    Future<void> Function(bool on)? setSpeaker,
    this.speakerSupported = false,
    this.ringTimeout = const Duration(seconds: 45),
  }) : _setSpeaker = setSpeaker ?? _platformSpeaker {
    _offers = service.incomingOffers.listen(_onOffer);
    _ends = service.terminations.listen(_onTerminated);
  }

  final NativeCallService service;

  /// This device's account, so an offer this account made is never shown as
  /// an incoming call.
  final String? selfAccountId;
  final bool speakerSupported;
  final Duration ringTimeout;
  final Future<void> Function(bool on) _setSpeaker;

  late final StreamSubscription<IncomingCallSignal> _offers;
  late final StreamSubscription<({String callId, String state})> _ends;
  StreamSubscription<MediaStream>? _remote;
  Timer? _ringTimer;
  bool _disposed = false;

  CallPhase phase = CallPhase.idle;
  String? conversationId;
  String? callId;
  bool video = false;
  bool muted = false;
  bool cameraOff = false;
  bool speakerOn = false;
  MediaStream? remoteStream;
  CallNotice? notice;
  DateTime? connectedAt;

  ActiveCall? _active;
  IncomingCallSignal? _incoming;
  int _generation = 0;

  bool get busy => phase != CallPhase.idle;
  bool get hasLocalVideo => _active?.hasLocalVideo ?? false;
  MediaStream? get localStream => _active?.localStream;

  /// Rings the other person of a direct conversation.
  Future<void> start(String conversation, {bool withVideo = false}) async {
    if (busy || _disposed) return;
    final generation = _begin(CallPhase.ringingOut, conversation, withVideo);
    try {
      final active = await service.start(conversation, video: withVideo);
      if (!_current(generation)) {
        unawaited(_endQuietly(active.session.id));
        return;
      }
      _bind(active);
      callId = active.session.id;
      // Nobody picked up: hang up rather than ring until the server expires.
      _ringTimer = Timer(ringTimeout, () {
        if (phase == CallPhase.ringingOut) {
          unawaited(hangUp(notice: CallNoticeKind.noAnswer));
        }
      });
      notifyListeners();
    } catch (_) {
      if (_current(generation)) _fail(conversation);
    }
  }

  /// Answers the ringing incoming call.
  Future<void> accept() async {
    final incoming = _incoming;
    if (phase != CallPhase.ringingIn || incoming == null) return;
    final generation = ++_generation;
    phase = CallPhase.connecting;
    video = incoming.signal['video'] == true;
    notifyListeners();
    try {
      final active = await service.answer(incoming.call, incoming.signal);
      if (!_current(generation)) {
        unawaited(_endQuietly(active.session.id));
        return;
      }
      _incoming = null;
      _bind(active);
      notifyListeners();
    } catch (_) {
      if (_current(generation)) _fail(incoming.call.conversationId);
    }
  }

  /// Declines the ringing incoming call.
  Future<void> decline() async {
    final incoming = _incoming;
    if (phase != CallPhase.ringingIn || incoming == null) return;
    _reset();
    try {
      await service.reject(incoming.call);
    } catch (_) {
      // The server expires the ringing call if the rejection cannot be sent.
    }
  }

  /// Ends the current call or cancels one still ringing.
  Future<void> hangUp({CallNoticeKind? notice}) async {
    final id = callId;
    final conversation = conversationId;
    if (phase == CallPhase.idle || id == null) {
      if (phase == CallPhase.ringingOut) _reset();
      return;
    }
    // (a callee still answering also has an id: handled below)
    final unanswered = _incoming;
    _reset();
    if (unanswered != null) {
      // The callee never reached 'active': the server only allows reject.
      unawaited(service.reject(unanswered.call).catchError((Object _) {}));
      return;
    }
    if (notice != null && conversation != null) {
      this.notice = CallNotice(notice, conversation);
    }
    notifyListeners();
    try {
      await service.end(id);
    } catch (_) {
      // Local media is already released; the server expires the call.
    }
  }

  void toggleMute() {
    final active = _active;
    if (active == null) return;
    muted = !muted;
    active.setMicrophoneEnabled(!muted);
    notifyListeners();
  }

  void toggleCamera() {
    final active = _active;
    if (active == null || !active.hasLocalVideo) return;
    cameraOff = !cameraOff;
    active.setCameraEnabled(!cameraOff);
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    if (!speakerSupported || _active == null) return;
    final next = !speakerOn;
    try {
      await _setSpeaker(next);
      speakerOn = next;
    } catch (_) {
      return;
    }
    notifyListeners();
  }

  void dismissNotice() {
    if (notice == null) return;
    notice = null;
    notifyListeners();
  }

  int _begin(CallPhase next, String conversation, bool withVideo) {
    final generation = ++_generation;
    phase = next;
    conversationId = conversation;
    video = withVideo;
    callId = null;
    muted = false;
    cameraOff = false;
    speakerOn = false;
    notice = null;
    connectedAt = null;
    notifyListeners();
    return generation;
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _bind(ActiveCall active) {
    _active = active;
    callId = active.session.id;
    final peer = active.peerConnection;
    peer.onConnectionState = (state) {
      if (_active != active || _disposed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connected();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        final conversation = conversationId;
        unawaited(hangUp());
        if (conversation != null) {
          notice = CallNotice(CallNoticeKind.failed, conversation);
          notifyListeners();
        }
      }
    };
    _remote = active.remoteStreams.listen((stream) {
      if (_active != active || _disposed) return;
      remoteStream = stream;
      _connected();
    });
  }

  void _connected() {
    if (phase == CallPhase.active) {
      notifyListeners();
      return;
    }
    _ringTimer?.cancel();
    phase = CallPhase.active;
    connectedAt = DateTime.now();
    notifyListeners();
  }

  void _onOffer(IncomingCallSignal incoming) {
    if (_disposed) return;
    final call = incoming.call;
    if (call.createdBy == selfAccountId) return;
    // A replayed offer of a call that has already expired must not ring.
    final expires = call.expiresAt;
    if (expires != null && !expires.isAfter(DateTime.now())) return;
    if (busy) {
      unawaited(service.reject(call).catchError((Object _) {}));
      notice = CallNotice(CallNoticeKind.busy, call.conversationId);
      notifyListeners();
      return;
    }
    _incoming = incoming;
    _begin(CallPhase.ringingIn, call.conversationId,
        incoming.signal['video'] == true);
    callId = call.id;
  }

  void _onTerminated(({String callId, String state}) end) {
    if (_disposed || end.callId != callId) return;
    final conversation = conversationId;
    final wasRinging = phase == CallPhase.ringingIn;
    final wasCalling = phase == CallPhase.ringingOut;
    _reset();
    if (conversation == null) return;
    // An unanswered incoming call is a missed call; an outgoing one that the
    // other side refused or never answered says so.
    if (wasRinging) {
      notice = CallNotice(CallNoticeKind.missed, conversation);
    } else if (wasCalling) {
      notice = CallNotice(
          end.state == 'rejected'
              ? CallNoticeKind.declined
              : CallNoticeKind.noAnswer,
          conversation);
    }
    notifyListeners();
  }

  void _fail(String conversation) {
    final id = callId;
    final unanswered = _incoming;
    _reset();
    if (unanswered != null) {
      unawaited(service.reject(unanswered.call).catchError((Object _) {}));
    } else if (id != null) {
      unawaited(_endQuietly(id));
    }
    notice = CallNotice(CallNoticeKind.failed, conversation);
    notifyListeners();
  }

  void _reset() {
    _generation++;
    _ringTimer?.cancel();
    _ringTimer = null;
    unawaited(_remote?.cancel());
    _remote = null;
    _active = null;
    _incoming = null;
    remoteStream = null;
    phase = CallPhase.idle;
    conversationId = null;
    callId = null;
    video = false;
    muted = false;
    cameraOff = false;
    if (speakerOn) unawaited(_setSpeaker(false).catchError((Object _) {}));
    speakerOn = false;
    connectedAt = null;
    notifyListeners();
  }

  Future<void> _endQuietly(String id) =>
      service.end(id).catchError((Object _) {});

  static Future<void> _platformSpeaker(bool on) => Helper.setSpeakerphoneOn(on);

  @override
  void dispose() {
    if (_disposed) return;
    final id = callId;
    final hadCall = phase != CallPhase.idle;
    _disposed = true;
    _ringTimer?.cancel();
    unawaited(_offers.cancel());
    unawaited(_ends.cancel());
    unawaited(_remote?.cancel());
    if (hadCall && id != null) {
      final unanswered = _incoming;
      if (unanswered != null) {
        unawaited(service.reject(unanswered.call).catchError((Object _) {}));
      } else {
        unawaited(_endQuietly(id));
      }
    }
    super.dispose();
  }
}
