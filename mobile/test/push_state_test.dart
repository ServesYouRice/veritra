import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/push/push_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// Card I41: provider-aware registration and typed push state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AppState, _PushApi, _FakePush)> start(Map<String, Object?> config,
      {PushEndpointEvent? pending}) async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    final api = _PushApi(config);
    final push = _FakePush()..pending = pending;
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
      pushService: push,
    );
    await state.tryRestoreSession();
    await _until(() =>
        push.registrations.isNotEmpty ||
        state.pushState == PushState.serverDisabled);
    return (state, api, push);
  }

  test('an FCM-only server registers without a VAPID key', () async {
    final (state, api, push) = await start(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    });
    expect(push.registrations.single.providers, <String>['fcm']);
    expect(push.registrations.single.vapid, '');
    expect(state.pushState, PushState.registering);

    push.emit(const PushEndpointEvent(
      instance: 'acct_1:dev_1',
      provider: 'fcm',
      endpoint: 'fcm-token-0123456789-0123456789-0123',
      publicKey: '',
      authSecret: '',
    ));
    await _until(() => state.pushState == PushState.registered);
    expect(state.pushProvider, 'fcm');
    expect(api.nativeRegistrations, <String>['fcm']);
    state.dispose();
  });

  test('a missing distributor and a refused token are told apart', () async {
    final (state, _, push) = await start(<String, Object?>{
      'enabled': true,
      'providers': <String>['webpush'],
      'vapid_public_key': 'vapid',
    });
    push.emit(
        const PushRegistrationFailedEvent('acct_1:dev_1', provider: 'webpush'));
    await _until(() => state.pushState == PushState.noDistributor);
    push.emit(
        const PushRegistrationFailedEvent('acct_1:dev_1', provider: 'fcm'));
    await _until(() => state.pushState == PushState.registrationFailed);
    // Another instance's events are ignored.
    push.emit(const PushRegistrationFailedEvent('other', provider: 'webpush'));
    await Future<void>.delayed(Duration.zero);
    expect(state.pushState, PushState.registrationFailed);
    state.dispose();
  });

  test('a unifiedpush distributor missing or refusing sets noDistributor',
      () async {
    final (state, _, push) = await start(<String, Object?>{
      'enabled': true,
      'providers': <String>['unifiedpush'],
      'vapid_public_key': 'vapid',
    });
    push.emit(const PushRegistrationFailedEvent('acct_1:dev_1',
        provider: 'unifiedpush'));
    await _until(() => state.pushState == PushState.noDistributor);
    state.dispose();
  });

  test('a UnifiedPush endpoint registers with provider unifiedpush', () async {
    final (state, api, push) = await start(<String, Object?>{
      'enabled': true,
      'providers': <String>['unifiedpush'],
      'vapid_public_key': 'vapid',
    });
    expect(push.registrations.single.providers, <String>['unifiedpush']);
    expect(push.registrations.single.vapid, 'vapid');

    push.emit(const PushEndpointEvent(
      instance: 'acct_1:dev_1',
      provider: 'unifiedpush',
      endpoint: 'https://up.example.com/endpoint/abc',
      publicKey: 'pubkey123',
      authSecret: 'auth123',
    ));
    await _until(() => state.pushState == PushState.registered);
    expect(state.pushProvider, 'unifiedpush');
    expect(api.webPushRegistrations.single.provider, 'unifiedpush');
    expect(api.webPushRegistrations.single.endpoint,
        'https://up.example.com/endpoint/abc');
    expect(api.webPushRegistrations.single.publicKey, 'pubkey123');
    expect(api.webPushRegistrations.single.authSecret, 'auth123');
    state.dispose();
  });

  test(
      'cold UnifiedPush rotations register without VAPID before acknowledgement',
      () async {
    for (final encrypted in <bool>[false, true]) {
      final (state, api, push) = await start(<String, Object?>{
        'enabled': true,
        'providers': <String>['unifiedpush'],
      },
          pending: PushEndpointEvent(
            instance: 'acct_1:dev_1',
            provider: 'unifiedpush',
            endpoint: 'https://push.example/wake',
            publicKey: encrypted ? 'public-key' : '',
            authSecret: encrypted ? 'auth-secret' : '',
            generation: 9,
          ));
      await _until(() => push.acknowledgedEndpoints.isNotEmpty);
      expect(push.registrations.single.vapid, '');
      expect(api.webPushRegistrations.single.provider, 'unifiedpush');
      expect(api.webPushRegistrations.single.publicKey,
          encrypted ? 'public-key' : '');
      expect(api.webPushRegistrations.single.authSecret,
          encrypted ? 'auth-secret' : '');
      expect(push.acknowledgedEndpoints, <int>[9]);
      expect(state.pushState, PushState.registered);
      state.dispose();
    }
  });

  test('a server without push says so and registers nothing', () async {
    final (state, _, push) =
        await start(<String, Object?>{'enabled': false, 'providers': []});
    expect(state.pushState, PushState.serverDisabled);
    expect(push.registrations, isEmpty);
    state.dispose();
  });

  test('permission is read at start and can be requested', () async {
    final (state, _, push) = await start(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    });
    expect(state.notificationPermission, NotificationPermission.notDetermined);
    push.permission = NotificationPermission.denied;
    await state.requestNotificationPermission();
    expect(state.notificationPermission, NotificationPermission.denied);
    state.dispose();
  });

  test('the test wake reports coarse results without identifiers', () async {
    final (state, api, push) = await start(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    });
    push.emit(const PushEndpointEvent(
      instance: 'acct_1:dev_1',
      provider: 'fcm',
      endpoint: 'fcm-token-0123456789-0123456789-0123',
      publicKey: '',
      authSecret: '',
    ));
    await _until(() => state.pushState == PushState.registered);

    api.testResults = <String>['delivered'];
    await state.sendTestPush();
    expect(state.pushTestResult, contains('Test sent'));

    api.testError = ApiException(429, '{"error":"push_test_rate_limited"}');
    await state.sendTestPush();
    expect(state.pushTestResult, contains('Wait a minute'));
    expect(state.pushTestResult, isNot(contains('fcm-token')));
    state.dispose();
  });

  const rotated = PushEndpointEvent(
    instance: 'acct_1:dev_1',
    provider: 'fcm',
    endpoint: 'fcm-token-rotated-0123456789-0123456789',
    publicKey: '',
    authSecret: '',
    generation: 7,
  );

  test(
      'a rotation stored before the subscriber exists is registered, then '
      'acknowledged only after the server accepted it', () async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    final api = _PushApi(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    });
    final push = _FakePush()..pending = rotated;
    // The stream emits nothing: the record is the only carrier.
    api.onRegister = () => expect(push.acknowledgedEndpoints, isEmpty);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
      pushService: push,
    );
    await state.tryRestoreSession();
    await _until(() => push.acknowledgedEndpoints.isNotEmpty);
    expect(api.registeredTokens, <String>[rotated.endpoint]);
    expect(push.acknowledgedEndpoints, <int>[7]);
    expect(push.pending, isNull);
    expect(state.pushState, PushState.registered);
    state.dispose();
  });

  Future<(AppState, _PushApi, _FakePush)> startWith(
      {Future<bool> Function()? installer, PushEndpointEvent? pending}) async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    final api = _PushApi(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    });
    final push = _FakePush()..pending = pending;
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
      pushService: push,
    )..phoneNoticeInstaller = installer;
    await state.tryRestoreSession();
    await _until(() => push.registrations.isNotEmpty);
    return (state, api, push);
  }

  test('phone notices are off by default: no notification mode is sent',
      () async {
    final (state, api, push) = await startWith(pending: rotated);
    await _until(() => push.acknowledgedEndpoints.isNotEmpty);
    push.emit(rotated);
    await _until(() => api.registeredModes.length == 2);
    expect(api.registeredModes, <String?>[null, null]);
    expect(state.phoneNoticesAllowed, isFalse);
    state.dispose();
  });

  test(
      'a worker that native allowed registers local_decrypt_v1 on a pending '
      'record and again on every later rotation', () async {
    var installs = 0;
    final (state, api, push) = await startWith(
        pending: rotated,
        installer: () async {
          installs++;
          return true;
        });
    await _until(() => push.acknowledgedEndpoints.isNotEmpty);
    push.emit(rotated);
    await _until(() => api.registeredModes.length == 2);
    expect(installs, 1);
    expect(
        api.registeredModes, <String?>['local_decrypt_v1', 'local_decrypt_v1']);
    state.dispose();
  });

  test('a refused or failing install never requests local_decrypt_v1',
      () async {
    for (final installer in <Future<bool> Function()>[
      () async => false,
      () async => throw StateError('no worker'),
    ]) {
      final (state, api, push) =
          await startWith(pending: rotated, installer: installer);
      await _until(() => push.acknowledgedEndpoints.isNotEmpty);
      expect(api.registeredModes, <String?>[null]);
      expect(state.phoneNoticesAllowed, isFalse);
      state.dispose();
    }
  });

  test('a failed server registration leaves the record unacknowledged',
      () async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    final api = _PushApi(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    })
      ..registerError = ApiException(503, '{"error":"unavailable"}');
    final push = _FakePush()..pending = rotated;
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
      pushService: push,
    );
    await state.tryRestoreSession();
    await _until(() => push.registrations.isNotEmpty);
    expect(push.acknowledgedEndpoints, isEmpty);
    expect(push.pending, same(rotated));
    expect(state.pushState, PushState.registrationFailed);
    state.dispose();
  });

  test('a record for another instance is dropped without being uploaded',
      () async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    final api = _PushApi(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    });
    final push = _FakePush()
      ..pending = const PushEndpointEvent(
        instance: 'acct_old:dev_old',
        provider: 'fcm',
        endpoint: 'stale-token-0123456789-0123456789-01',
        publicKey: '',
        authSecret: '',
        generation: 3,
      );
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
      pushService: push,
    );
    await state.tryRestoreSession();
    await _until(() => push.registrations.isNotEmpty);
    expect(api.registeredTokens, isEmpty);
    expect(push.acknowledgedEndpoints, <int>[3]);
    state.dispose();
  });

  test(
      'a live endpoint event is acknowledged with its generation, and an '
      'older acknowledgement keeps a newer rotation', () async {
    final (state, api, push) = await start(<String, Object?>{
      'enabled': true,
      'providers': <String>['fcm'],
    });
    // A newer rotation lands in the record while generation 7 is handled.
    const newer = PushEndpointEvent(
      instance: 'acct_1:dev_1',
      provider: 'fcm',
      endpoint: 'fcm-token-newer-0123456789-0123456789',
      publicKey: '',
      authSecret: '',
      generation: 8,
    );
    push.pending = newer;
    push.emit(rotated);
    await _until(() => push.acknowledgedEndpoints.contains(7));
    expect(api.registeredTokens, <String>[rotated.endpoint]);
    expect(push.pending, same(newer));
    state.dispose();
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _PushApi extends ApiClient with LegacySyncPageFake {
  _PushApi(this.config) : super(baseUrl: 'https://localhost:8080');

  final Map<String, Object?> config;
  final List<String> nativeRegistrations = <String>[];
  void Function()? onRegister;
  List<String> testResults = const <String>[];
  ApiException? testError;
  Object? registerError;
  final List<String> registeredTokens = <String>[];
  final List<String?> registeredModes = <String?>[];
  final List<
      ({
        String endpoint,
        String publicKey,
        String authSecret,
        String? mode,
        String provider
      })> webPushRegistrations = <({
    String endpoint,
    String publicKey,
    String authSecret,
    String? mode,
    String provider,
  })>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async => config;

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];

  @override
  Future<String> registerNativePush(String token,
      {required String provider,
      required String deviceToken,
      String? notificationMode}) async {
    registeredModes.add(notificationMode);
    onRegister?.call();
    final error = registerError;
    if (error != null) throw error;
    nativeRegistrations.add(provider);
    registeredTokens.add(deviceToken);
    return 'push_1';
  }

  @override
  Future<String> registerWebPush(
    String token, {
    String provider = 'webpush',
    required String endpoint,
    required String publicKey,
    required String authSecret,
    String? notificationMode,
  }) async {
    registeredModes.add(notificationMode);
    onRegister?.call();
    final error = registerError;
    if (error != null) throw error;
    webPushRegistrations.add((
      endpoint: endpoint,
      publicKey: publicKey,
      authSecret: authSecret,
      mode: notificationMode,
      provider: provider,
    ));
    registeredTokens.add(endpoint);
    return 'push_1';
  }

  @override
  Future<List<String>> sendTestPush(String token) async {
    final error = testError;
    if (error != null) throw error;
    return testResults;
  }
}

class _FakePush implements MobilePushService {
  final _events = StreamController<PushEvent>.broadcast();
  final List<({String instance, String vapid, List<String> providers})>
      registrations =
      <({String instance, String vapid, List<String> providers})>[];
  NotificationPermission permission = NotificationPermission.notDetermined;

  void emit(PushEvent event) => _events.add(event);

  @override
  Stream<PushEvent> get events => _events.stream;

  @override
  Future<void> register({
    required String instance,
    String vapid = '',
    List<String> providers = const <String>[],
  }) async {
    registrations.add((instance: instance, vapid: vapid, providers: providers));
  }

  @override
  Future<NotificationPermission> notificationPermission() async => permission;

  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      permission;

  @override
  Future<void> pickDistributor() async {}

  @override
  Future<void> unregister(String instance) async {}

  @override
  Future<int> pendingWakeGeneration() async => 0;

  @override
  Future<bool> acknowledgeWake(int generation) async => false;

  PushEndpointEvent? pending;
  final List<int> acknowledgedEndpoints = <int>[];

  @override
  Future<PushEndpointEvent?> pendingEndpoint() async => pending;

  @override
  Future<bool> acknowledgeEndpoint(int generation) async {
    acknowledgedEndpoints.add(generation);
    if (pending?.generation != generation) return false;
    pending = null;
    return true;
  }

  @override
  void dispose() => unawaited(_events.close());
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
