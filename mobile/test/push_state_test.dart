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

  Future<(AppState, _PushApi, _FakePush)> start(
      Map<String, Object?> config) async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_1',
      deviceId: 'dev_1',
    ));
    final api = _PushApi(config);
    final push = _FakePush();
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
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _PushApi extends ApiClient {
  _PushApi(this.config) : super(baseUrl: 'https://localhost:8080');

  final Map<String, Object?> config;
  final List<String> nativeRegistrations = <String>[];
  List<String> testResults = const <String>[];
  ApiException? testError;

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
      {required String provider, required String deviceToken}) async {
    nativeRegistrations.add(provider);
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
  void dispose() => _controller.close();
}
