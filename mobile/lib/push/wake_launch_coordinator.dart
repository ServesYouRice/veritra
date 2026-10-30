import 'dart:async';

import 'wake_worker_bridge.dart';

/// Query native launch context before constructing storage or crypto. A cold
/// wake can start only the compiled profile's existing-state callback. A later
/// real view attachment enters UI setup once, using that same application's
/// owner; it never chooses an entry point/profile from native preferences.
class WakeLaunchCoordinator {
  WakeLaunchCoordinator({
    required this.bridge,
    required this.profile,
    required this.onUi,
    this.onBackground,
    this.beforeUi,
    this.onAttachment,
    this.onUiError,
  });

  final PlatformWakeWorkerBridge bridge;
  final String profile;
  final Future<void> Function() onUi;
  final Future<void> Function()? onBackground;
  final Future<void> Function()? beforeUi;
  final void Function(bool)? onAttachment;
  final void Function()? onUiError;
  Future<void>? _starting;
  Future<void>? _backgroundSetup;
  Future<void>? _uiSetup;
  bool _known = false;
  bool _attached = false;
  bool _attachmentObserved = false;
  bool _disposed = false;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    bridge.observeUiAttachment((attached) {
      if (_disposed) return;
      _attachmentObserved = true;
      _attached = attached;
      onAttachment?.call(attached);
      if (attached && _known) unawaited(_enterUi());
    });
    final WakeBootstrap bootstrap;
    try {
      // This RPC is read-only. Ignore a late reply; never infer UI launch from
      // timeout or a malformed/unknown native protocol.
      bootstrap = await bridge.bootstrap().timeout(const Duration(seconds: 2));
    } catch (_) {
      _known = true;
      if (_attached && !_disposed) await _enterUi();
      return;
    }
    if (_disposed) return;
    _known = true;
    if (!_attachmentObserved) _attached = bootstrap.uiAttached;
    if (!bootstrap.launchBackground || _attached) {
      await _enterUi();
      return;
    }
    final startBackground = onBackground;
    if (!bootstrap.nativeSilent ||
        bootstrap.boundProfile != profile ||
        startBackground == null) return;
    final completed = Completer<void>();
    _backgroundSetup = completed.future;
    try {
      await startBackground();
    } catch (_) {
      // Locked/missing protected state stays quiet. Actual UI attachment can
      // still enter normal explicit recovery through the same compiled root.
    } finally {
      completed.complete();
    }
  }

  Future<void> _enterUi() => _uiSetup ??= _startUi();

  Future<void> _startUi() async {
    try {
      // Revoke/cancel before waiting for background setup/atomic work to drain.
      await beforeUi?.call();
      await _backgroundSetup;
      // Setup may have installed its owner after the first cancellation while
      // awaiting protected storage. Fence/drain that late installation too.
      await beforeUi?.call();
      if (!_disposed) await onUi();
    } catch (_) {
      if (!_disposed) onUiError?.call();
    }
  }

  void dispose() => _disposed = true;
}
