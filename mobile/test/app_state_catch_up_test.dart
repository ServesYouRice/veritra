import 'dart:async';
import 'dart:io';

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

/// The catch-up loop in [AppState]: received messages whose publication
/// failed (TASK-031), undecryptable peer messages under D54 (TASK-032),
/// storage errors around the recovery record (TASK-034) and projection
/// refreshes per run of events (TASK-036).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('received messages whose publication failed (TASK-031)', () {
    test('are shown once by the next catch-up, even with no new events',
        () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          _envelopeEvent(4, 'msg_one'),
          _envelopeEvent(5, 'msg_two'),
        ];
      // Reading history to show the page fails once.
      final store = _FlakyStore()..historyFailures = 1;
      final published = <String>[];
      final harness = await _Harness.start(api,
          store: store, configure: _recordPublished(published));

      await harness.waitFor(() => harness.state.syncError != null);
      expect(await store.loadSyncCursor(), 5);
      expect(store.historyFailures, 0);
      expect(harness.state.messagesFor('conv_1'), isEmpty);
      expect(published, isEmpty);

      // Nothing new on the server.
      harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await harness.waitFor(() => published.isNotEmpty);
      expect(published, <String>['msg_one', 'msg_two']);
      expect(harness.state.messagesFor('conv_1').map((item) => item.id),
          unorderedEquals(<String>['msg_one', 'msg_two']));
      await harness.waitFor(() => harness.state.syncError == null);

      // Shown exactly once.
      harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await harness.settle();
      await harness.waitFor(() => harness.state.syncError == null);
      expect(published, <String>['msg_one', 'msg_two']);
      expect(api.syncCalls, greaterThanOrEqualTo(3));
      harness.dispose();
    });

    test('a failed batch and its retry are both kept for the next catch-up',
        () async {
      // The 50th envelope fills a batch; showing it fails, and so does the
      // retry after the failure.
      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          for (var id = 1; id <= 51; id++) _envelopeEvent(id, 'msg_$id'),
        ];
      final store = _FlakyStore()..historyFailures = 2;
      final published = <String>[];
      final harness = await _Harness.start(api,
          store: store, configure: _recordPublished(published));

      await harness.waitFor(() => harness.state.syncError != null);
      expect(await store.loadSyncCursor(), 50);
      expect(store.historyFailures, 0);
      expect(published, isEmpty);

      harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await harness.waitFor(() => published.length >= 51);
      await harness.waitFor(() => harness.state.syncError == null);
      expect(published, <String>[for (var id = 1; id <= 51; id++) 'msg_$id']);
      expect(harness.state.messagesFor('conv_1'), hasLength(51));
      harness.dispose();
    });

    test('are dropped when the session changes', () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[_envelopeEvent(4, 'msg_one')];
      final store = _FlakyStore()..historyFailures = 1;
      await _keepIdentity(store);
      final published = <String>[];
      final harness = await _Harness.start(api,
          store: store, configure: _recordPublished(published));
      await harness.waitFor(() => harness.state.syncError != null);
      expect(await store.loadSyncCursor(), 4);

      // Signed out and in again before any catch-up could show them.
      await harness.state.logout();
      await harness.state.login('https://localhost:8080', 'me', 'password');
      await harness.waitFor(() => harness.state.lastSyncedAt != null);
      await harness.settle();

      expect(await store.loadSyncCursor(), 4);
      expect(published, isEmpty);
      expect(harness.state.messagesFor('conv_1'), isEmpty);
      harness.dispose();
    });
  });

  group('a peer message that can never be decrypted (D54, TASK-032)', () {
    test('gets a placeholder and sync goes on for other conversations',
        () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          _envelopeEvent(4, 'msg_locked', ciphertext: _neverDecrypts),
          _envelopeEvent(5, 'msg_ok', conversationId: 'conv_2'),
        ];
      final store = MemoryLocalStore();
      await _keepIdentity(store);
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() async => await store.loadSyncCursor() == 5);
      await harness.waitFor(() => harness.state.lastSyncedAt != null);
      expect(harness.state.syncRecovery, isNull);
      expect(await store.loadSyncRecovery(), isNull);
      expect(harness.crypto.applied, <String>['msg_locked', 'msg_ok']);
      expect(harness.state.messagesFor('conv_2').single.id, 'msg_ok');
      // The locked one is shown as its placeholder, with no content.
      final locked = harness.state.messagesFor('conv_1').single;
      final row = harness.state.historyFor('conv_1').forEnvelope(locked)!;
      expect(row.key, 'undecryptable:4:msg_locked');
      expect(row.kind, LocalMessageKind.invalid);
      expect(row.body, isNull);
      harness.dispose();
    });

    test('a failed MLS control message still stops all sync (I33)', () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          _mlsEvent(4, 'mls_bad'),
          _envelopeEvent(5, 'msg_ok', conversationId: 'conv_2'),
        ];
      final store = MemoryLocalStore();
      final harness = await _Harness.start(api, store: store);
      harness.crypto.rejectedMls.add('mls_bad');

      await harness.waitFor(() => harness.state.syncRecovery != null);
      expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsState);
      expect((await store.loadSyncRecovery())!.eventId, 4);
      expect(await store.loadSyncCursor(), 0);
      expect(harness.crypto.applied, isEmpty);
      harness.dispose();
    });

    test('a stop recorded for it before D54 is cleared once and applied',
        () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          _envelopeEvent(4, 'msg_locked', ciphertext: _neverDecrypts),
          _envelopeEvent(5, 'msg_ok'),
        ];
      final store = MemoryLocalStore();
      await _keepIdentity(store);
      await store.saveSyncRecovery(SyncRecovery(
        kind: SyncFailureKind.applicationUndecryptable,
        recordedAt: DateTime.utc(2026, 10, 1),
        eventId: 4,
        eventType: 'message.envelope.created',
        conversationId: 'conv_1',
      ));
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() async => await store.loadSyncCursor() == 5);
      await harness.waitFor(() => harness.state.lastSyncedAt != null);
      expect(harness.state.syncRecovery, isNull);
      expect(harness.state.deviceRecoveryRequired, isFalse);
      expect(await store.loadSyncRecovery(), isNull);
      expect(harness.crypto.applied, <String>['msg_locked', 'msg_ok']);

      // Only once: a later stop of this kind (a failure the crypto service
      // still refuses) stays until the person picks a recovery choice.
      final calls = api.syncCalls;
      await store.saveSyncRecovery(SyncRecovery(
        kind: SyncFailureKind.applicationUndecryptable,
        recordedAt: DateTime.utc(2026, 11, 1),
        eventId: 6,
      ));
      harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await harness.waitFor(() => harness.state.syncRecovery != null);
      await harness.settle();
      expect(harness.state.syncRecovery!.eventId, 6);
      expect(await store.loadSyncRecovery(), isNotNull);
      expect(api.syncCalls, calls);
      harness.dispose();
    });

    test('other stored stops are not cleared', () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[_envelopeEvent(4, 'msg_ok')];
      final store = MemoryLocalStore();
      await store.saveSyncRecovery(SyncRecovery(
        kind: SyncFailureKind.mlsState,
        recordedAt: DateTime.utc(2026, 10, 1),
        eventId: 3,
      ));
      final harness = await _Harness.start(api, store: store);
      await harness.waitFor(() => harness.state.syncRecovery != null);
      await harness.settle();
      expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsState);
      expect(await store.loadSyncRecovery(), isNotNull);
      expect(api.syncCalls, 0);
      harness.dispose();
    });
  });

  // Each test fails on an uncaught asynchronous error: catch-ups run
  // unawaited, so nothing may escape them.
  group('storage errors around the recovery record (TASK-034)', () {
    test('a passing error reading it goes offline and is retried', () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[_projectionEvent(4, 'conversation.updated')];
      final store = _FlakyStore()..recoveryReadFailures = 1;
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() =>
          harness.state.syncError == harness.state.l10n.syncErrorStorageBusy);
      expect(harness.state.connectionStatus, ConnectionStatus.offline);
      expect(harness.state.syncRecovery, isNull);
      expect(api.syncCalls, 0);
      // The scheduled retry catches up without any wake.
      await harness.waitFor(() async => await store.loadSyncCursor() == 4);
      await harness.waitFor(() => harness.state.syncError == null);
      expect(harness.state.connectionStatus, ConnectionStatus.online);
      harness.dispose();
    });

    test('a lasting error reading it records a local storage recovery',
        () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[_projectionEvent(4, 'conversation.updated')];
      final store = _FlakyStore()
        ..recoveryReadFailures = 1
        ..recoveryReadError = _refused;
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() => harness.state.syncRecovery != null);
      expect(harness.state.syncRecovery!.kind, SyncFailureKind.localStorage);
      expect(harness.state.deviceRecoveryRequired, isTrue);
      expect(harness.state.connectionStatus, ConnectionStatus.offline);
      expect(
          (await store.loadSyncRecovery())!.kind, SyncFailureKind.localStorage);
      expect(api.syncCalls, 0);
      harness.dispose();
    });

    test('a refused write of the record still stops sync in memory', () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[_projectionEvent(4, 'conversation.updated')];
      final store = _FlakyStore()
        ..syncCommitFailures = 1
        ..refuseRecoveryWrites = true;
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() => harness.state.syncRecovery != null);
      await harness.settle();
      expect(harness.state.syncRecovery!.kind, SyncFailureKind.localStorage);
      expect(harness.state.deviceRecoveryRequired, isTrue);
      expect(harness.state.connectionStatus, ConnectionStatus.offline);
      expect(harness.state.syncError, isNotNull);
      store.refuseRecoveryWrites = false;
      expect(await store.loadSyncRecovery(), isNull);
      expect(await store.loadSyncCursor(), 0);
      harness.dispose();
    });

    test('a sign-out that fails in storage after a 401 does not escape',
        () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[_projectionEvent(4, 'conversation.updated')]
        ..syncStatus = 401;
      final store = _FlakyStore()..refuseClear = true;
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() => store.clearAttempts > 0);
      await harness.settle();
      expect(harness.state.syncRecovery, isNull);
      expect(await store.loadSyncRecovery(), isNull);
      harness.dispose();
    });
  });

  group('projection refreshes per run of events (TASK-036)', () {
    Future<_ScriptedApi> catchUp(List<SyncEvent> events, int cursor) async {
      final api = _ScriptedApi()..events = events;
      final store = MemoryLocalStore();
      final harness = await _Harness.start(api, store: store);
      await harness.waitFor(() async => await store.loadSyncCursor() == cursor);
      await harness.waitFor(() => harness.state.lastSyncedAt != null);
      await harness.settle();
      harness.dispose();
      return api;
    }

    test('a burst of device events costs one device and list refresh',
        () async {
      final one =
          await catchUp(<SyncEvent>[_projectionEvent(1, 'device.updated')], 1);
      final burst = await catchUp(<SyncEvent>[
        for (var id = 1; id <= 50; id++) _projectionEvent(id, 'device.updated'),
      ], 50);
      expect(burst.deviceCalls, one.deviceCalls);
      expect(burst.conversationCalls, one.conversationCalls);
    });

    test('each run is refreshed and committed before the next message',
        () async {
      // The same two runs, of one event each.
      final single = await catchUp(<SyncEvent>[
        _projectionEvent(1, 'conversation.updated'),
        _envelopeEvent(2, 'msg_a'),
        _projectionEvent(3, 'conversation.updated'),
        _envelopeEvent(4, 'msg_b'),
      ], 4);

      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          _projectionEvent(1, 'conversation.updated'),
          _projectionEvent(2, 'membership.added'),
          _envelopeEvent(3, 'msg_a'),
          _projectionEvent(4, 'conversation.updated'),
          _projectionEvent(5, 'retention.updated'),
          _envelopeEvent(6, 'msg_b'),
        ];
      final store = MemoryLocalStore();
      final harness = await _Harness.start(api, store: store);
      await harness.waitFor(() async => await store.loadSyncCursor() == 6);
      await harness.waitFor(() => harness.state.lastSyncedAt != null);
      await harness.settle();

      // A message is applied only once the run before it is committed.
      expect(harness.crypto.cursorAtApply, <int>[2, 5]);
      expect(api.conversationCalls, single.conversationCalls);
      harness.dispose();
    });

    test('a failed refresh commits none of its run', () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          _projectionEvent(1, 'conversation.updated'),
          _envelopeEvent(2, 'msg_a'),
          _projectionEvent(3, 'conversation.updated'),
          _projectionEvent(4, 'device.updated'),
        ]
        ..failDevicesDuringSync = true;
      final store = MemoryLocalStore();
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() => harness.state.syncError != null);
      expect(await store.loadSyncCursor(), 2);
      expect(harness.crypto.applied, <String>['msg_a']);

      api.failDevicesDuringSync = false;
      harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await harness.waitFor(() async => await store.loadSyncCursor() == 4);
      expect(harness.crypto.applied, <String>['msg_a']);
      harness.dispose();
    });
  });
}

SyncEvent _projectionEvent(int id, String type,
        {String? conversationId = 'conv_1'}) =>
    SyncEvent(
      id: id,
      type: type,
      conversationId: conversationId,
      payload: const <String, Object?>{},
      createdAt: DateTime.utc(2026, 9, 24),
    );

/// The ciphertext [_FakeMlsCrypto] treats as one this device can never
/// decrypt (D54).
const _neverDecrypts = <int>[9];

SyncEvent _mlsEvent(int id, String messageId) => SyncEvent(
      id: id,
      type: 'mls.message.created',
      conversationId: 'conv_1',
      payload: <String, Object?>{'mls_message_id': messageId},
      createdAt: DateTime.utc(2026, 9, 24),
    );

void Function(AppState) _recordPublished(List<String> published) =>
    (state) => state.onMessagesPublished =
        (items) => published.addAll(items.map((item) => item.id));

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
