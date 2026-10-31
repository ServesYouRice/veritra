// A user-started refresh whose session ended or was replaced while it ran
// publishes nothing to the new session: no list, no loaded flag and no
// error (TASK-027).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _sessionA = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token-a',
  accountId: 'acct_a',
  deviceId: 'dev_a',
);
const _sessionB = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token-b',
  accountId: 'acct_b',
  deviceId: 'dev_b',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState stateFor(_Api api) => AppState(
        apiClientFactory: (_) => api,
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _NoopSync(),
      )
        ..api = api
        ..session = _sessionA;

  test('a stale device list is not published', () async {
    final api = _Api();
    final state = stateFor(api);
    final refresh = state.refreshDevices();
    await Future<void>.delayed(Duration.zero);
    state.session = _sessionB;
    api.gate.complete();
    await refresh;
    expect(state.devices, isEmpty);
    expect(state.devicesLoaded, isFalse);
    state.dispose();
  });

  test('a stale refresh error is not shown to the new session', () async {
    final api = _Api()..failure = ApiException(503, '{"error":"down"}');
    final state = stateFor(api);
    final refresh = state.refreshDevices();
    await Future<void>.delayed(Duration.zero);
    state.session = _sessionB;
    api.gate.complete();
    await refresh;
    expect(state.errorFor(Ops.devices), isNull);
    expect(state.session, _sessionB);
    state.dispose();
  });

  test('a stale 401 does not sign the new session out', () async {
    final api = _Api()..failure = ApiException(401, '{"error":"no"}');
    final state = stateFor(api);
    final refresh = state.refreshDevices();
    await Future<void>.delayed(Duration.zero);
    state.session = _sessionB;
    api.gate.complete();
    await refresh;
    expect(state.session, _sessionB);
    expect(state.errorFor(Ops.devices), isNull);
    state.dispose();
  });
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  final Completer<void> gate = Completer<void>();
  ApiException? failure;

  @override
  Future<List<Device>> devices(String token) async {
    await gate.future;
    final error = failure;
    if (error != null) throw error;
    return <Device>[
      Device(
        id: 'dev_a',
        accountId: 'acct_a',
        name: 'phone',
        createdAt: DateTime.utc(2026, 10, 1),
      ),
    ];
  }
}

class _NoopSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
