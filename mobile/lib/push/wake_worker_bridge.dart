import 'dart:async';

import 'package:flutter/services.dart';

enum WakeOutcome { committed, noChange, retry, unavailable }

enum WakeNoticeResult { shown, suppressed, unavailable }

class WakeBootstrap {
  const WakeBootstrap(
      {required this.launchBackground,
      this.boundProfile,
      required this.uiAttached,
      required this.nativeSilent,
      required this.canOptIn});
  final bool launchBackground, uiAttached, nativeSilent, canOptIn;
  final String? boundProfile;
}

class WakePermit {
  const WakePermit(
      {required this.permit,
      required this.profile,
      required this.wakeGeneration,
      required this.budgetMs,
      required this.deadlineEpochMs});
  final String permit, profile;
  final int wakeGeneration, budgetMs, deadlineEpochMs;
  Map<String, Object> get identity =>
      {'protocol': 1, 'permit': permit, 'profile': profile};
}

class WakeCancellation {
  const WakeCancellation(this.permit, this.profile, this.reason);
  final String permit, profile, reason;
}

class WakePermitStatus {
  const WakePermitStatus(this.active, this.remainingMs);
  final bool active;
  final int remainingMs;
}

/// Native worker wiring is distinct from server capability opt-in. This bridge
/// never creates storage, selects an entry point, or claims platform readiness.
class PlatformWakeWorkerBridge {
  PlatformWakeWorkerBridge({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('org.veritra.private_messenger/wake_worker');
  final MethodChannel _channel;
  static final Set<String> _ownedChannels = {};
  bool _ownsChannel = false;
  bool _observingUi = false;
  String? _profile;
  String? _running;
  Future<WakeOutcome> Function(WakePermit)? _run;
  Future<void> Function(WakeCancellation)? _cancel;
  void Function(bool)? _ui;
  bool _disposed = false;

  static Never _invalid() =>
      throw const FormatException('invalid native wake protocol');
  static bool _matches(String pattern, String value) =>
      RegExp(pattern).stringMatch(value) == value;
  static Map<Object?, Object?> _map(Object? value, Set<String> keys,
      {bool protocol = true}) {
    if (value is! Map ||
        value.keys.any((key) => !keys.contains(key)) ||
        (protocol && value['protocol'] != 1)) _invalid();
    return value;
  }

  static bool _bool(Object? value) {
    if (value is! bool) _invalid();
    return value;
  }

  static int _int(Object? value, int min, int max) {
    if (value is! int || value < min || value > max) _invalid();
    return value;
  }

  static String _profileName(Object? value) {
    if (value is! String || !_matches(r'^[a-z][a-z0-9-]{0,39}$', value))
      _invalid();
    return value;
  }

  static String _permitName(Object? value) {
    if (value is! String ||
        !_matches(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
            value)) _invalid();
    return value;
  }

  Future<WakeBootstrap> bootstrap() async {
    try {
      final map = _map(await _channel.invokeMethod<Object?>('bootstrap'), {
        'protocol',
        'launch',
        'bound_profile',
        'ui_attached',
        'native_silent',
        'can_opt_in'
      });
      if (map['launch'] != 'ui' && map['launch'] != 'background') _invalid();
      final bound = map['bound_profile'];
      if (_bool(map['can_opt_in'])) _invalid();
      return WakeBootstrap(
          launchBackground: map['launch'] == 'background',
          boundProfile: bound == null ? null : _profileName(bound),
          uiAttached: _bool(map['ui_attached']),
          nativeSilent: _bool(map['native_silent']),
          canOptIn: _bool(map['can_opt_in']));
    } on MissingPluginException {
      return const WakeBootstrap(
          launchBackground: false,
          uiAttached: true,
          nativeSilent: false,
          canOptIn: false);
    }
  }

  /// Observe view attachment without a profile, storage, crypto or worker.
  /// A quiet headless root can later enter its normal UI setup exactly once.
  void observeUiAttachment(void Function(bool) observer) {
    if (_disposed ||
        (!_ownsChannel && _ownedChannels.contains(_channel.name))) {
      throw StateError('native wake channel already has an owner');
    }
    _ownedChannels.add(_channel.name);
    _ownsChannel = true;
    _observingUi = true;
    _ui = observer;
    _channel.setMethodCallHandler(_handle);
  }

  Future<bool> install(
      {required String profile,
      required Future<WakeOutcome> Function(WakePermit) onRun,
      required Future<void> Function(WakeCancellation) onCancel,
      void Function(bool)? onUiAttached}) async {
    _profileName(profile);
    if (_disposed ||
        (_profile != null && _profile != profile) ||
        (!_ownsChannel && _ownedChannels.contains(_channel.name))) return false;
    _ownedChannels.add(_channel.name);
    _ownsChannel = true;
    _profile = profile;
    _run = onRun;
    _cancel = onCancel;
    if (onUiAttached != null) _ui = onUiAttached;
    _channel.setMethodCallHandler(_handle);
    var installed = false;
    try {
      final map = _map(
          await _channel.invokeMethod<Object?>(
              'install', {'protocol': 1, 'profile': profile}),
          {'protocol', 'native_silent', 'worker_attached', 'can_opt_in'});
      // Until the separate activation review, no bridge caller may interpret
      // native installation as authorization to request extra phone wakes.
      if (_bool(map['can_opt_in'])) _invalid();
      installed = _bool(map['native_silent']) && _bool(map['worker_attached']);
      return installed;
    } on MissingPluginException {
      return false;
    } finally {
      if (!installed) {
        if (!_observingUi) _release();
        _profile = null;
        _run = null;
        _cancel = null;
      }
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'uiAttached') {
      final map = _map(call.arguments, {'protocol', 'attached'});
      _ui?.call(_bool(map['attached']));
      return null;
    }
    if (call.method == 'cancel') {
      final map =
          _map(call.arguments, {'protocol', 'permit', 'profile', 'reason'});
      final permit = _permitName(map['permit']),
          profile = _profileName(map['profile']);
      if (profile != _profile ||
          !const {'deadline', 'os_stop', 'unregistered'}
              .contains(map['reason'])) return false;
      await _cancel
          ?.call(WakeCancellation(permit, profile, map['reason'] as String));
      return true;
    }
    if (call.method != 'run') throw MissingPluginException();
    final map = _map(call.arguments, {
      'protocol',
      'permit',
      'profile',
      'wake_generation',
      'budget_ms',
      'deadline_epoch_ms'
    });
    final permit = WakePermit(
        permit: _permitName(map['permit']),
        profile: _profileName(map['profile']),
        wakeGeneration: _int(map['wake_generation'], 1, 0x7fffffffffffffff),
        budgetMs: _int(map['budget_ms'], 1, 20000),
        deadlineEpochMs: _int(map['deadline_epoch_ms'], 1, 0x7fffffffffffffff));
    var outcome = WakeOutcome.unavailable;
    if (permit.profile == _profile && _running == null && _run != null) {
      _running = permit.permit;
      try {
        outcome = await _run!(permit);
      } catch (_) {
        outcome = WakeOutcome.retry;
      } finally {
        _running = null;
      }
    }
    return {
      ...permit.identity,
      'wake_generation': permit.wakeGeneration,
      'outcome': switch (outcome) {
        WakeOutcome.noChange => 'no_change',
        _ => outcome.name,
      }
    };
  }

  Future<WakePermitStatus> validatePermit(WakePermit permit) async {
    if (_disposed || permit.profile != _profile)
      return const WakePermitStatus(false, 0);
    final map = _map(
        await _channel.invokeMethod<Object?>('validatePermit', permit.identity),
        {'active', 'remaining_ms'},
        protocol: false);
    final active = _bool(map['active']);
    final remaining = _int(map['remaining_ms'], 0, 20000);
    if (active != (remaining > 0)) _invalid();
    return WakePermitStatus(active, remaining);
  }

  Future<WakeNoticeResult> presentGenericNotice(
      WakePermit permit, String noticeId) async {
    if (_disposed || permit.profile != _profile)
      return WakeNoticeResult.unavailable;
    if (!_matches(r'^[0-9a-f]{32}$', noticeId)) _invalid();
    final value = await _channel.invokeMethod<Object?>(
        'presentGenericNotice', {...permit.identity, 'notice_id': noticeId});
    return switch (value) {
      'shown' => WakeNoticeResult.shown,
      'suppressed' => WakeNoticeResult.suppressed,
      'unavailable' => WakeNoticeResult.unavailable,
      _ => _invalid()
    };
  }

  Future<bool> uninstall(String profile) async {
    _profileName(profile);
    if (_profile != null && _profile != profile) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'uninstall', {'protocol': 1, 'profile': profile}) ??
          false;
    } on MissingPluginException {
      return false;
    } finally {
      _release();
      _profile = null;
      _run = null;
      _cancel = null;
      _ui = null;
    }
  }

  void _release() {
    if (!_ownsChannel) return;
    _channel.setMethodCallHandler(null);
    _ownedChannels.remove(_channel.name);
    _ownsChannel = false;
    _observingUi = false;
  }

  void dispose() {
    _disposed = true;
    _release();
    _run = null;
    _cancel = null;
    _ui = null;
  }
}
