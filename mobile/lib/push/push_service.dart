import 'dart:async';

import 'package:flutter/services.dart';

sealed class PushEvent {
  const PushEvent();
}

class PushEndpointEvent extends PushEvent {
  const PushEndpointEvent({
    required this.instance,
    required this.endpoint,
    required this.publicKey,
    required this.authSecret,
  });

  final String instance;
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

abstract class MobilePushService {
  Stream<PushEvent> get events;
  Future<void> register({required String instance, required String vapid});
  Future<void> pickDistributor();
  Future<void> unregister(String instance);
  Future<bool> takePendingWake();
  void dispose();
}

class DisabledMobilePushService implements MobilePushService {
  @override
  Stream<PushEvent> get events => const Stream<PushEvent>.empty();

  @override
  Future<void> register(
      {required String instance, required String vapid}) async {}

  @override
  Future<void> pickDistributor() async {}

  @override
  Future<void> unregister(String instance) async {}

  @override
  Future<bool> takePendingWake() async => false;

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
        final endpoint = event['endpoint'];
        final publicKey = event['publicKey'];
        final authSecret = event['authSecret'];
        if (instance is String &&
            endpoint is String &&
            publicKey is String &&
            authSecret is String) {
          _events.add(PushEndpointEvent(
            instance: instance,
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
    }
  }

  @override
  Future<void> register({required String instance, required String vapid}) =>
      _methods.invokeMethod<void>('register', <String, String>{
        'instance': instance,
        'vapid': vapid,
      });

  @override
  Future<void> pickDistributor() =>
      _methods.invokeMethod<void>('pickDistributor');

  @override
  Future<void> unregister(String instance) => _methods.invokeMethod<void>(
        'unregister',
        <String, String>{'instance': instance},
      );

  @override
  Future<bool> takePendingWake() async =>
      await _methods.invokeMethod<bool>('takeWake') ?? false;

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_events.close());
  }
}
