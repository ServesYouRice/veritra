import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart' show SqliteException;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Follow-ups to the catch-up lane: the one-time D54 clear clears before it
/// marks itself done, and envelopes an earlier pass could not show never
/// block a later pass.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unshown envelopes whose history still cannot be read do not block sync',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_envelopeEvent(4, 'msg_one')];
    final store = _FlakyStore()..historyFailures = 1;
    final harness = await _Harness.start(api, store: store);
    await harness.waitFor(() => harness.state.syncError != null);
    expect(await store.loadSyncCursor(), 4);

    // The history read keeps failing; a new event arrives.
    store.historyFailures = 1000;
    api.events = <SyncEvent>[...api.events, _envelopeEvent(5, 'msg_two')];
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() async => await store.loadSyncCursor() == 5);
    expect(harness.crypto.applied, <String>['msg_one', 'msg_two']);

    // Once history reads again, both are shown.
    store.historyFailures = 0;
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness
        .waitFor(() => harness.state.messagesFor('conv_1').length == 2);
    await harness.waitFor(() => harness.state.syncError == null);
    harness.dispose();
  });

  test('a failed one-time clear of a pre-D54 stop is tried again', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _envelopeEvent(4, 'msg_locked', ciphertext: _neverDecrypts),
      ];
    final store = _FlakyStore()..recoveryClearFailures = 1;
    await _keepIdentity(store);
    await store.saveSyncRecovery(SyncRecovery(
      kind: SyncFailureKind.applicationUndecryptable,
      recordedAt: DateTime.utc(2026, 10, 1),
      eventId: 4,
      eventType: 'message.envelope.created',
      conversationId: 'conv_1',
    ));
    final harness = await _Harness.start(api, store: store);
    await harness.waitFor(() => store.recoveryClearFailures == 0);
    await harness.waitFor(() => harness.state.syncError != null);
    expect(harness.state.syncRecovery, isNull);

    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() async => await store.loadSyncCursor() == 4);
    await harness.waitFor(() => harness.state.lastSyncedAt != null);
    expect(harness.state.syncRecovery, isNull);
    expect(await store.loadSyncRecovery(), isNull);
    harness.dispose();
  });

  for (final code in <int>[11, 26]) {
    test(
        'a damaged database ($code) offers the confirmed reset, not Retry only',
        () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[_envelopeEvent(4, 'msg_one')];
      final store = MemoryLocalStore();
      await _keepIdentity(store);
      final harness = await _Harness.start(api,
          store: store,
          configure: (state) =>
              (state.cryptoService as _FakeMlsCrypto).applyError =
                  SqliteException(extendedResultCode: code, message: 'test'));
      final state = harness.state;
      await harness
          .waitFor(() => state.lifecycle == SessionLifecycle.recoveryRequired);
      expect(state.session, isNull);
      expect(state.canResetLocalData, isTrue);
      expect(state.canContinueWithoutRestore, isFalse);
      expect(state.recoveryMessage, state.l10n.recoveryStorageDamaged);
      expect(state.syncRecovery, isNull);
      expect(await store.loadSyncRecovery(), isNull);
      expect(await store.loadSyncCursor(), 0);

      await state.resetUnreadableLocalData(confirmed: true);
      expect(state.lifecycle, SessionLifecycle.ready);
      expect(state.session, isNull);
      expect(state.canResetLocalData, isFalse);
      harness.dispose();
    });
  }

  test('another durable storage error still stops with Retry only', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_envelopeEvent(4, 'msg_one')];
    final store = MemoryLocalStore();
    await _keepIdentity(store);
    final harness = await _Harness.start(api,
        store: store,
        configure: (state) =>
            (state.cryptoService as _FakeMlsCrypto).applyError =
                SqliteException(extendedResultCode: 19, message: 'test'));
    final state = harness.state;
    await harness.waitFor(() => state.syncRecovery != null);
    expect(state.syncRecovery!.kind, SyncFailureKind.localStorage);
    expect(state.lifecycle, SessionLifecycle.ready);
    expect(state.canResetLocalData, isFalse);
    harness.dispose();
  });

  test('a damaged database stop keeps nothing of the account for the next',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_envelopeEvent(4, 'msg_one')];
    final store = MemoryLocalStore();
    await _keepIdentity(store);
    final harness = await _Harness.start(api, store: store);
    final state = harness.state;
    await harness.waitFor(() => state.lastSyncedAt != null);
    state.blocksLoaded = true;
    expect(state.conversations, isNotEmpty);
    expect(state.requestStateLoaded, isTrue);

    // The next pass finds the database damaged.
    harness.crypto.applyError =
        SqliteException(extendedResultCode: 11, message: 'test');
    api.events = <SyncEvent>[...api.events, _envelopeEvent(5, 'msg_two')];
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness
        .waitFor(() => state.lifecycle == SessionLifecycle.recoveryRequired);

    await state.resetUnreadableLocalData(confirmed: true);
    expect(state.lifecycle, SessionLifecycle.ready);
    expect(state.requestStateLoaded, isFalse,
        reason: "the old account's accepted peers must not carry over");
    expect(state.conversations, isEmpty);
    expect(state.conversationsLoaded, isFalse);
    expect(state.historyOnlyConversations, isEmpty);
    expect(state.blocksLoaded, isFalse);
    expect(state.messagesFor('conv_1'), isEmpty);

    harness.dispose();
  });
}

/// The ciphertext [_FakeMlsCrypto] treats as one this device can never
/// decrypt (D54).
const _neverDecrypts = <int>[9];

/// Protected MLS state, so signing in again keeps this device's identity
/// and its cursor.
Future<void> _keepIdentity(LocalStore store) => store.saveCryptoState(
    StoredCryptoState(
        counter: 1,
        stateKey: List<int>.filled(32, 7),
        sealedState: const <int>[1]),
    0);

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);

SyncEvent _envelopeEvent(int id, String messageId,
        {List<int> ciphertext = const <int>[1],
        String conversationId = 'conv_1'}) =>
    SyncEvent(
      id: id,
      type: 'message.envelope.created',
      conversationId: conversationId,
      payload: <String, Object?>{
        'message_id': messageId,
        'conversation_id': conversationId,
        'envelope': ReceivedMessageEnvelope(
          id: messageId,
          conversationId: conversationId,
          senderAccountId: 'acct_peer',
          senderDeviceId: 'dev_peer',
          idempotencyKey: 'idem_$messageId',
          ciphertext: ciphertext,
          cryptoProtocol: 'mls10-openmls-v1',
          createdAt: DateTime.utc(2026, 9, 24, 0, 0, id),
        ).toJson(),
      },
      createdAt: DateTime.utc(2026, 9, 24),
    );

class _Harness {
  _Harness(this.state, this.store, this.crypto);

  final AppState state;
  final LocalStore store;
  final _FakeMlsCrypto crypto;

  static Future<_Harness> start(_ScriptedApi api,
      {LocalStore? store, void Function(AppState state)? configure}) async {
    final local = store ?? MemoryLocalStore();
    await local.saveSession(_session);
    final crypto = _FakeMlsCrypto(local);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: local,
      syncServiceFactory: (_, __) => _QuietSync(),
    );
    configure?.call(state);
    await state.tryRestoreSession();
    return _Harness(state, local, crypto);
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitFor(FutureOr<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    fail('condition not reached');
  }

  void dispose() => state.dispose();
}

/// EBUSY: a storage error that passes by itself.
const _busy = FileSystemException('busy', '', OSError('busy', 16));

/// EACCES: a storage error that does not pass by itself.
const _refused = FileSystemException('refused', '', OSError('refused', 13));

/// A memory store whose reads and writes fail a set number of times.
class _FlakyStore extends MemoryLocalStore {
  int historyFailures = 0;
  int recoveryReadFailures = 0;
  Object recoveryReadError = _busy;
  bool refuseRecoveryWrites = false;
  int syncCommitFailures = 0;
  bool refuseClear = false;
  int clearAttempts = 0;
  int recoveryClearFailures = 0;

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) async {
    if (historyFailures > 0) {
      historyFailures--;
      throw _busy;
    }
    return super.loadMessages(conversationId);
  }

  @override
  Future<SyncRecovery?> loadSyncRecovery() async {
    if (recoveryReadFailures > 0) {
      recoveryReadFailures--;
      throw recoveryReadError;
    }
    return super.loadSyncRecovery();
  }

  @override
  Future<void> saveSyncRecovery(SyncRecovery? recovery) async {
    if (refuseRecoveryWrites) throw _refused;
    if (recovery == null && recoveryClearFailures > 0) {
      recoveryClearFailures--;
      throw _busy;
    }
    return super.saveSyncRecovery(recovery);
  }

  @override
  Future<void> commitSyncEvent(SyncEventCommit commit) async {
    if (syncCommitFailures > 0 && commit.eventKey.startsWith('sync:')) {
      syncCommitFailures--;
      throw _refused;
    }
    return super.commitSyncEvent(commit);
  }

  @override
  Future<void> clearCachedState(
      {bool preserveOutbox = false, bool keepDrafts = false}) async {
    clearAttempts++;
    if (refuseClear) throw _refused;
    return super.clearCachedState(
        preserveOutbox: preserveOutbox, keepDrafts: keepDrafts);
  }
}

class _ScriptedApi extends ApiClient {
  _ScriptedApi() : super(baseUrl: 'https://localhost:8080');

  List<SyncEvent> events = <SyncEvent>[];
  int? syncStatus;
  int syncCalls = 0;
  int conversationCalls = 0;
  int deviceCalls = 0;
  bool failDevicesDuringSync = false;

  @override
  Future<List<Conversation>> conversations(String token) async {
    conversationCalls++;
    return <Conversation>[
      Conversation(id: 'conv_1', kind: 'group'),
      Conversation(id: 'conv_2', kind: 'group'),
    ];
  }

  @override
  Future<List<Device>> devices(String token) async {
    deviceCalls++;
    if (failDevicesDuringSync && syncCalls > 0) {
      throw ApiException(503, '{"error":"unavailable"}');
    }
    return const <Device>[];
  }

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    syncCalls++;
    if (syncStatus == 401) {
      throw ApiException(401, '{"error":"unauthorized"}');
    }
    return events
        .where((event) => event.id > after)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<Session> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceSecret,
  }) async =>
      Session(
        baseUrl: baseUrl,
        token: 'token_again',
        accountId: 'acct_me',
        deviceId: deviceId,
        username: username,
      );

  @override
  Future<void> publishDeviceKeyPackages(
    String token,
    List<List<int>> keyPackages, {
    Duration lifetime = const Duration(days: 14),
  }) async {}

  @override
  Future<ReceivedMessageEnvelope> message(
          String token, String messageId) async =>
      throw ApiException(404, '{"error":"not_found"}');

  MlsMessage _mls(SyncEvent event) => MlsMessage(
        id: (event.payload as Map)['mls_message_id'] as String,
        conversationId: event.conversationId!,
        senderAccountId: 'acct_peer',
        senderDeviceId: 'dev_peer',
        kind: 'commit',
        payload: const <int>[1],
        idempotencyKey: 'idem_${event.id}',
        syncEventId: event.id,
        createdAt: DateTime.utc(2026, 9, 24),
      );

  @override
  Future<List<MlsMessage>> mlsMessages(
    String token, {
    int after = 0,
    int limit = 100,
  }) async =>
      <MlsMessage>[
        for (final event in events)
          if (event.type == 'mls.message.created' && event.id > after)
            _mls(event),
      ].take(limit).toList(growable: false);

  @override
  Future<MlsMessage> mlsMessage(String token, String messageId) async =>
      _mls(events.firstWhere((event) =>
          event.type == 'mls.message.created' &&
          (event.payload as Map)['mls_message_id'] == messageId));
}

class _FakeMlsCrypto implements MlsConversationCryptoService {
  _FakeMlsCrypto(this.store);

  final LocalStore store;
  final List<String> applied = <String>[];
  final List<int> cursorAtApply = <int>[];
  final Set<String> rejectedMls = <String>{};

  /// Thrown by the next application message, once.
  Object? applyError;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<void> processMlsMessage(MlsMessage message) async {
    if (rejectedMls.contains(message.id)) throw StateError('commit rejected');
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'mls:${message.syncEventId}:${message.id}',
      conversationId: message.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: message.syncEventId,
    ));
  }

  @override
  Future<List<int>?> processApplicationMessage(
      ReceivedMessageEnvelope envelope, int syncEventId) async {
    applied.add(envelope.id);
    final error = applyError;
    if (error != null) {
      applyError = null;
      throw error;
    }
    cursorAtApply.add(await store.loadSyncCursor());
    if (envelope.ciphertext.length == 1 &&
        envelope.ciphertext.single == _neverDecrypts.single) {
      // What NativeCryptoService commits for a message it can never
      // decrypt (D54): the same group state, the cursor, and a placeholder
      // row with no content.
      final previous = (await store.loadCryptoState())!;
      await store.commitMlsTransition(MlsStateTransition(
        messageId: 'application:$syncEventId:${envelope.id}',
        conversationId: envelope.conversationId,
        expectedCounter: previous.counter,
        expectedCursor: await store.loadSyncCursor(),
        state: StoredCryptoState(
            counter: previous.counter + 1,
            stateKey: previous.stateKey,
            sealedState: previous.sealedState),
        cursor: syncEventId,
        upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
        messageEffects: <MessageEffect>[
          InsertMessageEffect(
            key: 'undecryptable:$syncEventId:${envelope.id}',
            serverMessageId: envelope.id,
            conversationId: envelope.conversationId,
            senderAccountId: envelope.senderAccountId,
            senderDeviceId: envelope.senderDeviceId,
            kind: LocalMessageKind.invalid,
            createdAt: envelope.createdAt.millisecondsSinceEpoch,
            state: LocalMessageState.received,
          ),
        ],
      ));
      return null;
    }
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'application:$syncEventId:${envelope.id}',
      conversationId: envelope.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: syncEventId,
    ));
    return null;
  }

  @override
  Future<List<List<int>>> createReplenishmentKeyPackages(
          {int count = 5}) async =>
      <List<int>>[
        for (var i = 0; i < count; i++) <int>[i]
      ];

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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
