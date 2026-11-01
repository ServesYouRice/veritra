import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/push/background_wake_runner.dart';
import 'package:private_messenger/push/push_service.dart';
import 'package:private_messenger/push/wake_worker_bridge.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// D70 S4: a background wake never applies a Welcome for a conversation
/// the user left whose group is still to be dropped. The drop is a user's
/// deferred leave and runs only in the foreground, so the wake hands the
/// event back and commits nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a wake hands a re-add Welcome of a left chat to the foreground',
      () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
        0);
    await store.saveSetting(
        'mls.left_conversations',
        jsonEncode(<String, Object?>{
          'scope': '${canonicalizeServerOrigin(_origin)}\u0000alice\u0000phone',
          'ids': <String>['conv'],
        }));
    final api = _FakeApi()..events.add(_welcome(1));
    final crypto = _FakeCrypto(store);
    final state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: crypto,
        localStore: store,
        pushService: DisabledMobilePushService(),
        syncServiceFactory: (_, __) => _QuietSync());
    addTearDown(state.dispose);
    state.handleAppLifecycleState(AppLifecycleState.detached);
    final runner = BackgroundWakeRunner(
        profile: 'demo',
        bridge: _FakeBridge(),
        restoreExisting: state.restoreForBackgroundWake,
        catchUp: state.catchUpForBackgroundWake,
        mayStart: () => !state.foregroundActive);

    final outcome = await runner.run(WakePermit(
        permit: 'permit-1',
        profile: 'demo',
        wakeGeneration: 1,
        budgetMs: 20000,
        deadlineEpochMs: DateTime.now().millisecondsSinceEpoch + 20000));
    expect(outcome, isNot(WakeOutcome.committed));
    expect(await store.loadSyncCursor(), 0);
    expect(crypto.processed, isEmpty);
    expect(crypto.deleted, isEmpty);
    expect(await store.loadSetting('mls.left_conversations'), contains('conv'));
  });
}

const _origin = 'https://example.test';
const _session = Session(
    baseUrl: _origin, token: 'token', accountId: 'alice', deviceId: 'phone');

SyncEvent _welcome(int id) => SyncEvent(
      id: id,
      type: 'mls.message.created',
      conversationId: 'conv',
      payload: <String, Object?>{'mls_message_id': 'mls_$id'},
      createdAt: DateTime.utc(2026, 9, 24),
    );

class _FakeBridge extends PlatformWakeWorkerBridge {
  @override
  Future<WakePermitStatus> validatePermit(WakePermit permit) async =>
      const WakePermitStatus(true, 20000);
  @override
  Future<WakeNoticeResult> presentGenericNotice(
          WakePermit permit, String noticeId) async =>
      WakeNoticeResult.shown;
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: _origin);
  final List<SyncEvent> events = [];

  MlsMessage _mls(SyncEvent event) => MlsMessage(
        id: (event.payload as Map)['mls_message_id'] as String,
        conversationId: event.conversationId!,
        senderAccountId: 'bob',
        senderDeviceId: 'dev_bob',
        kind: 'welcome',
        payload: const <int>[1],
        idempotencyKey: 'idem_${event.id}',
        syncEventId: event.id,
        createdAt: DateTime.utc(2026, 9, 24),
        recipientDeviceId: _session.deviceId,
      );

  @override
  void close() {}
  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      events.where((e) => e.id > after).take(limit).toList();
  @override
  Future<List<MlsMessage>> mlsMessages(String token,
          {int after = 0, int limit = 100}) async =>
      [
        for (final e in events)
          if (e.id > after) _mls(e)
      ].take(limit).toList();
  @override
  Future<MlsMessage> mlsMessage(String token, String messageId) async =>
      _mls(events.firstWhere(
          (e) => (e.payload as Map)['mls_message_id'] == messageId));
  @override
  Future<List<BlockedAccount>> listBlocks(String token) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw const SocketException('not available in this test');
}

class _FakeCrypto
    implements
        BoundedMlsConversationCryptoService,
        MlsStateMaintenanceCryptoService,
        NoticeCaptureConsumer,
        ConversationAuthorityConsumer {
  _FakeCrypto(this.store);
  final MemoryLocalStore store;
  final List<String> processed = [];
  final List<String> deleted = [];
  @override
  bool noticeCaptureEnabled = false;
  @override
  set conversationAuthority(ConversationAuthority authority) {}

  @override
  Future<void> activateExistingSessionBounded(Session session,
      {required void Function() checkCanCommit}) async {
    checkCanCommit();
  }

  @override
  Future<void> processMlsMessageBounded(MlsMessage message,
      {required void Function() checkCanCommit}) async {
    processed.add(message.id);
  }

  @override
  Future<void> processMlsMessage(MlsMessage message) async {
    processed.add(message.id);
  }

  @override
  Future<bool> deleteConversationState(String conversationId) async {
    deleted.add(conversationId);
    return true;
  }

  @override
  Future<int> pruneExpiredKeyPackages(DateTime now) async => 0;
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
