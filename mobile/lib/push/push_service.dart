import 'dart:async';

import 'package:flutter/services.dart';

sealed class PushEvent {
  const PushEvent();
}

class PushEndpointEvent extends PushEvent {
  const PushEndpointEvent({
    required this.instance,
    this.provider = 'webpush',
    required this.endpoint,
    required this.publicKey,
    required this.authSecret,
  });

  final String instance;
  final String provider;
  final String endpoint;
  final String publicKey;
  final String authSecret;
}

class PushWakeEvent extends PushEvent {
  const PushWakeEvent();
}

class PushUnregisteredEvent extends PushEvent {
  const PushUnregisteredEvent(this.instance);
  final String instance;
}

/// The platform could not register (card I41): no UnifiedPush distributor,
/// or a provider token request failed. It carries no platform error text,
/// which can contain identifiers.
class PushRegistrationFailedEvent extends PushEvent {
  const PushRegistrationFailedEvent(this.instance, {this.provider});
  final String instance;
  final String? provider;
}

/// Whether this app may show notifications (card I41).
enum NotificationPermission {
  /// Allowed.
  granted,

  /// Refused; only the system settings can change it.
  denied,

  /// Not asked yet (Android 13+, iOS).
  notDetermined,

  /// This platform shows no notifications.
  unsupported,
}

NotificationPermission _permissionFrom(Object? value) {
  switch (value) {
    case 'granted':
      return NotificationPermission.granted;
    case 'denied':
      return NotificationPermission.denied;
    case 'not_determined':
      return NotificationPermission.notDetermined;
    default:
      return NotificationPermission.unsupported;
  }
}

abstract class MobilePushService {
  Stream<PushEvent> get events;

  /// Registers with the first platform provider in [providers] (the ones
  /// the server offers) that this build supports. [vapid] is needed only
  /// for Web Push (UnifiedPush); FCM and APNs never use it.
  Future<void> register({
    required String instance,
    String vapid = '',
    List<String> providers = const <String>[],
  });
  Future<NotificationPermission> notificationPermission();

  /// Asks the user once; returns the resulting permission.
  Future<NotificationPermission> requestNotificationPermission();
  Future<void> pickDistributor();
  Future<void> unregister(String instance);
  Future<int> pendingWakeGeneration();
  Future<bool> acknowledgeWake(int generation);
  void dispose();
}

class DisabledMobilePushService implements MobilePushService {
  @override
  Stream<PushEvent> get events => const Stream<PushEvent>.empty();

  @override
  Future<void> register({
    required String instance,
    String vapid = '',
    List<String> providers = const <String>[],
  }) async {}

  @override
  Future<NotificationPermission> notificationPermission() async =>
      NotificationPermission.unsupported;

  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      NotificationPermission.unsupported;

  @override
  Future<void> pickDistributor() async {}

  @override
  Future<void> unregister(String instance) async {}

  @override
  Future<int> pendingWakeGeneration() async => 0;

  @override
  Future<bool> acknowledgeWake(int generation) async => false;

  @override
  void dispose() {}
}

class PlatformMobilePushService implements MobilePushService {
  PlatformMobilePushService() {
    _subscription = _eventChannel.receiveBroadcastStream().listen(_onEvent);
  }

  static const _methods = MethodChannel(
    'org.veritra.private_messenger/push_methods',
  );
  static const _eventChannel = EventChannel(
    'org.veritra.private_messenger/push_events',
  );

  final _events = StreamController<PushEvent>.broadcast();
  StreamSubscription<Object?>? _subscription;

  @override
  Stream<PushEvent> get events => _events.stream;

  void _onEvent(Object? raw) {
    if (raw is! Map) return;
    final event = Map<String, Object?>.from(raw);
    switch (event['type']) {
      case 'endpoint':
        final instance = event['instance'];
        final provider = event['provider'];
        final endpoint = event['endpoint'];
        final publicKey = event['publicKey'];
        final authSecret = event['authSecret'];
        if (instance is String &&
            provider is String &&
            endpoint is String &&
            publicKey is String &&
            authSecret is String) {
          _events.add(PushEndpointEvent(
            instance: instance,
            provider: provider,
            endpoint: endpoint,
            publicKey: publicKey,
            authSecret: authSecret,
          ));
        }
      case 'wake':
        _events.add(const PushWakeEvent());
      case 'unregistered':
        final instance = event['instance'];
        if (instance is String) _events.add(PushUnregisteredEvent(instance));
      case 'registration_failed':
        final instance = event['instance'];
        final provider = event['provider'];
        if (instance is String) {
          _events.add(PushRegistrationFailedEvent(instance,
              provider: provider is String ? provider : null));
        }
    }
  }

  @override
  Future<void> register({
    required String instance,
    String vapid = '',
    List<String> providers = const <String>[],
  }) =>
      _methods.invokeMethod<void>('register', <String, Object>{
        'instance': instance,
        'vapid': vapid,
        'providers': providers,
      });

  @override
  Future<NotificationPermission> notificationPermission() async =>
      _permissionFrom(
          await _methods.invokeMethod<Object?>('notificationPermission'));

  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      _permissionFrom(await _methods
          .invokeMethod<Object?>('requestNotificationPermission'));

  @override
  Future<void> pickDistributor() =>
      _methods.invokeMethod<void>('pickDistributor');

  @override
  Future<void> unregister(String instance) => _methods.invokeMethod<void>(
        'unregister',
        <String, String>{'instance': instance},
      );

  @override
  Future<int> pendingWakeGeneration() async {
    final value = await _methods.invokeMethod<Object?>('pendingWakeGeneration');
    return value is num ? value.toInt() : 0;
  }

  @override
  Future<bool> acknowledgeWake(int generation) async {
    if (generation <= 0) return false;
    return await _methods.invokeMethod<bool>(
          'acknowledgeWake',
          <String, int>{'generation': generation},
        ) ??
        false;
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_events.close());
  }
}
