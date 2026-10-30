import 'dart:async';

import 'wake_worker_bridge.dart';

class WakeWorkCancelled implements Exception {
  const WakeWorkCancelled();
  @override
  String toString() => 'background wake cancelled';
}

/// The adapter reports durable work, never merely a completed HTTP response.
class WakeCatchUpResult {
  const WakeCatchUpResult({
    required this.caughtUp,
    required this.decisionsDurable,
    required this.changed,
  });
  final bool caughtUp;
  final bool decisionsDurable;
  final bool changed;
}

/// One short-lived native permit. A cancellation closes permit-owned clients;
/// it never destroys a native device or interrupts a database transaction.
class WakeRunContext {
  WakeRunContext._(this.permit, this._bridge) {
    _clock.start();
    _limitMs = permit.budgetMs;
    _armDeadline();
  }

  final WakePermit permit;
  final PlatformWakeWorkerBridge _bridge;
  final Stopwatch _clock = Stopwatch();
  final Set<void Function()> _cancellations = {};
  Timer? _deadline;
  late int _limitMs;
  bool _cancelled = false;
  bool Function()? _owner;

  bool get ownerBound => _owner != null;
  int get remainingMs =>
      (_limitMs - _clock.elapsedMilliseconds).clamp(0, 20000);
  bool get active => !_cancelled && remainingMs > 0 && (_owner?.call() ?? true);

  void checkCanCommit() {
    if (!ownerBound || !active) {
      cancel();
      throw const WakeWorkCancelled();
    }
  }

  /// Bind exactly once after opening the existing protected session. The
  /// closure compares that exact session/profile generation, not a later one.
  void bindOwner(bool Function() isStillOwner) {
    if (_owner != null || !active) throw const WakeWorkCancelled();
    _owner = isStillOwner;
    if (!active) cancel();
  }

  /// Register actual transport cancellation (for example, close(force:true)
  /// on this job's dedicated HttpClient). Do not register a UI/shared client.
  void Function() onCancel(void Function() abort) {
    if (!active) {
      abort();
      return () {};
    }
    _cancellations.add(abort);
    return () => _cancellations.remove(abort);
  }

  void _armDeadline() {
    _deadline?.cancel();
    _deadline = Timer(Duration(milliseconds: remainingMs), cancel);
  }

  /// Check before starting another operation and immediately before entering
  /// the atomic crypto/storage commit. Native time can only shorten this run.
  Future<void> check({bool requireOwner = true}) async {
    if (!active || (requireOwner && !ownerBound)) {
      cancel();
      throw const WakeWorkCancelled();
    }
    final WakePermitStatus status;
    try {
      // Validation is read-only. A lost platform reply must not hold the
      // worker forever; a late reply has no authority to extend this permit.
      status = await _bridge
          .validatePermit(permit)
          .timeout(Duration(milliseconds: remainingMs));
    } on TimeoutException {
      cancel();
      throw const WakeWorkCancelled();
    }
    if (!status.active || status.remainingMs <= 0 || !active) {
      cancel();
      throw const WakeWorkCancelled();
    }
    final nativeLimit = _clock.elapsedMilliseconds + status.remainingMs;
    if (nativeLimit < _limitMs) {
      _limitMs = nativeLimit;
      _armDeadline();
    }
    if (!active) {
      cancel();
      throw const WakeWorkCancelled();
    }
  }

  /// The caller must first commit an eligible, deduplicated notice decision.
  /// Only its opaque local ID crosses the native boundary.
  Future<WakeNoticeResult> presentDecision(String noticeId) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(noticeId)) {
      throw const FormatException('invalid local notice identity');
    }
    await check();
    try {
      // Native presentation is independently deadline-fenced and idempotent
      // for this durable notice ID. A late reply cannot authorize more work.
      return await _bridge
          .presentGenericNotice(permit, noticeId)
          .timeout(Duration(milliseconds: remainingMs));
    } on TimeoutException {
      cancel();
      throw const WakeWorkCancelled();
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _deadline?.cancel();
    final aborts = List<void Function()>.of(_cancellations);
    _cancellations.clear();
    for (final abort in aborts) {
      try {
        abort();
      } catch (_) {
        // A failing transport closer cannot keep another request alive.
      }
    }
  }
}

/// Coordinates one worker inside the process's existing engine/AppState.
/// Adapters must use the shared sync owner, existing-only storage and the
/// context's commit fence. This class never opens a profile or crypto itself.
class BackgroundWakeRunner {
  BackgroundWakeRunner({
    required this.profile,
    required this.bridge,
    required this.restoreExisting,
    required this.catchUp,
    required this.mayStart,
  });

  final String profile;
  final PlatformWakeWorkerBridge bridge;
  final Future<bool> Function(WakeRunContext) restoreExisting;
  final Future<WakeCatchUpResult> Function(WakeRunContext) catchUp;
  final bool Function() mayStart;
  WakeRunContext? _active;
  Future<WakeOutcome>? _work;
  bool _disposed = false;

  Future<WakeOutcome> run(WakePermit permit) {
    if (_disposed ||
        _active != null ||
        !mayStart() ||
        permit.profile != profile ||
        permit.budgetMs < 1 ||
        permit.budgetMs > 20000 ||
        permit.wakeGeneration < 1) {
      return Future.value(WakeOutcome.unavailable);
    }
    final context = WakeRunContext._(permit, bridge);
    _active = context;
    final work = _run(context);
    _work = work;
    return work;
  }

  Future<WakeOutcome> _run(WakeRunContext context) async {
    try {
      await context.check(requireOwner: false);
      if (!await restoreExisting(context)) return WakeOutcome.unavailable;
      await context.check();
      final result = await catchUp(context);
      await context.check();
      if (!result.caughtUp || !result.decisionsDurable)
        return WakeOutcome.retry;
      return result.changed ? WakeOutcome.committed : WakeOutcome.noChange;
    } on WakeWorkCancelled {
      return WakeOutcome.retry;
    } catch (_) {
      // No diagnostic body/key/path/token is propagated into native results.
      return WakeOutcome.retry;
    } finally {
      context.cancel();
      if (identical(_active, context)) _active = null;
    }
  }

  Future<void> cancel(WakeCancellation cancellation) async {
    final context = _active;
    if (context != null &&
        context.permit.permit == cancellation.permit &&
        context.permit.profile == cancellation.profile) context.cancel();
  }

  void cancelForForeground() => _active?.cancel();

  /// Cancellation stops new operations. Wait for any atomic in-flight work
  /// before a replacement sync owner takes over; Future.timeout is no fence.
  Future<void> drain() async {
    await _work;
  }

  Future<void> dispose() async {
    _disposed = true;
    _active?.cancel();
    await drain();
  }
}
