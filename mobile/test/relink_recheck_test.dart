// Relinking deletes local data. The banner's confirmation dialog can stay
// open while recovery ends or the session changes, so a confirmed relink
// runs only while the same session is still stopped at a failure that
// offers it (C-f4bf51f0c756).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({AppState state, MemoryLocalStore store})> signedIn() async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _NoopSync(),
    )
      ..api = api
      ..session = _session;
    return (state: state, store: store);
  }

  SyncRecovery recovery(SyncFailureKind kind) =>
      SyncRecovery(kind: kind, recordedAt: DateTime.utc(2026, 10, 31));

  test('does nothing once recovery has cleared', () async {
    final (:state, :store) = await signedIn();
    state.syncRecovery = null;
    await state.relinkAfterSyncRecovery(confirmed: true);
    expect(state.session, _session);
    expect(await store.loadSession(), isNotNull);
    state.dispose();
  });

  test('does nothing when the recovery no longer offers relink', () async {
    final (:state, :store) = await signedIn();
    state.syncRecovery = recovery(SyncFailureKind.localStorage);
    await state.relinkAfterSyncRecovery(confirmed: true);
    expect(state.session, _session);
    expect(await store.loadSession(), isNotNull);
    state.dispose();
  });

  test('still relinks while recovery offers it', () async {
    final (:state, :store) = await signedIn();
    state.syncRecovery = recovery(SyncFailureKind.cursorExpired);
    await state.relinkAfterSyncRecovery(confirmed: true);
    expect(state.session, isNull);
    expect(await store.loadSession(), isNull);
    state.dispose();
  });
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  @override
  Future<void> logout(String token) async {}

  @override
  void close() {}
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
