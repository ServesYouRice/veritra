// Membership reconcile (I51) is isolated per conversation: one refused add
// never stops reconcile for the other conversations, and the refused one is
// tried again on the next pass.
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

  test('a refused add in one conversation does not stop the others', () async {
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
    await _until(() => api.claims.length >= 3);
    expect(api.claims.take(3), ['conv-a', 'conv-b', 'conv-c']);
    expect(crypto.staged, ['conv-b', 'conv-c'],
        reason: 'a refusal for conv-a must not skip the later conversations');

    // The refused conversation is tried again on the next pass.
    api.refuse = false;
    state.handleAppLifecycleState(AppLifecycleState.paused);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await _until(() => crypto.staged.contains('conv-a'));
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not reached');
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: _origin);
  final List<String> claims = [];
  bool refuse = true;

  @override
  void close() {}
  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const [];
  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async => const [];
  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async => [
        for (final id in ['conv-a', 'conv-b', 'conv-c'])
          MlsPendingChange(
              conversationId: id,
              epoch: 3,
              add: const [(accountId: 'bob', deviceId: 'dev_bob')],
              remove: const []),
      ];
  @override
  Future<List<DeviceKeyPackage>> claimDeviceKeyPackages(
      String token, String conversationId, List<String> deviceIds) async {
    claims.add(conversationId);
    if (refuse && conversationId == 'conv-a') {
      // A server listing a device that is already a member now refuses it.
      throw ApiException(409, '{"error":"idempotency_conflict"}');
    }
    return [
      DeviceKeyPackage(
          id: 'kp-$conversationId',
          deviceId: 'dev_bob',
          accountId: 'bob',
          keyPackage: const [1],
          ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)))
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw const SocketException('not available in this test');
}

class _Crypto implements MlsConversationCryptoService {
  final List<String> staged = [];
  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      (epoch: 3, pending: false);
  @override
  Future<void> stageMembershipChange(String conversationId,
      {List<DeviceKeyPackage> adds = const [],
      List<MlsDeviceRef> removes = const []}) async {
    staged.add(conversationId);
  }

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
