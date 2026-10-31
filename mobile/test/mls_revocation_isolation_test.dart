// A revocation this device coordinates but cannot commit (no local group, or
// no leaf for the revoked device) must not fail the sync pass: the other
// revocations are still handled and membership reconcile still runs.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const _origin = 'https://example.test';
const _session = Session(
    baseUrl: _origin,
    token: 'token',
    accountId: 'alice',
    deviceId: 'dev_alice',
    deviceSecret: 'secret');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a revocation that cannot be committed does not fail the pass',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
        0);
    final api = _Api();
    final crypto = _Crypto();
    final state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: crypto,
        localStore: store,
        syncServiceFactory: (_, __) => _QuietSync());
    addTearDown(state.dispose);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await state.tryRestoreSession();
    await _until(() => api.claims.isNotEmpty);
    expect(crypto.attempted, ['conv-x', 'conv-y'],
        reason: 'a failed revocation must not skip the later ones');
    expect(crypto.committed, ['conv-y']);
    expect(api.claims, contains('conv-a'),
        reason: 'membership reconcile must still run after the failure');
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not reached');
}

MlsRevocation _revocation(String conversationId) => MlsRevocation(
    conversationId: conversationId,
    revokedDeviceId: 'dev_bob_tablet',
    revokedAccountId: 'bob',
    coordinatorDeviceId: 'dev_alice',
    state: 'pending',
    commitMessageId: null,
    requestedAt: DateTime.utc(2026, 10, 31));

class _Api extends ApiClient {
  _Api() : super(baseUrl: _origin);
  final List<String> claims = [];

  @override
  void close() {}
  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const [];
  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      [_revocation('conv-x'), _revocation('conv-y')];
  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async => [
        MlsPendingChange(
            conversationId: 'conv-a',
            epoch: 3,
            add: const [(accountId: 'carol', deviceId: 'dev_carol')],
            remove: const []),
      ];
  @override
  Future<List<DeviceKeyPackage>> claimDeviceKeyPackages(
      String token, String conversationId, List<String> deviceIds) async {
    claims.add(conversationId);
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw const SocketException('not available in this test');
}

class _Crypto implements MlsConversationCryptoService {
  final List<String> attempted = [];
  final List<String> committed = [];

  @override
  Future<void> createRevocationCommit(MlsRevocation revocation) async {
    attempted.add(revocation.conversationId);
    if (revocation.conversationId == 'conv-x') {
      // What the native core reports for a group this device never joined.
      throw StateError('no local group');
    }
    committed.add(revocation.conversationId);
  }

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      (epoch: 3, pending: false);
  @override
  Future<void> activateSession(Session session) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
