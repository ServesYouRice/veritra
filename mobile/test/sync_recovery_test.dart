import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Card I33: typed per-event failures, durable recovery, bounded repair and
/// the tombstone policy for proven-expired application messages.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a missing MLS control message stops sync without a poison loop',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_gone')]
      ..mlsMissing.add('mls_gone');
    final harness = await _Harness.start(api);

    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsControlMissing);
    expect(harness.state.syncRecovery!.eventId, 5);
    expect(harness.state.deviceRecoveryRequired, isTrue);
    expect(await harness.store.loadSyncCursor(), 0);
    expect((await harness.store.loadSyncRecovery())!.kind,
        SyncFailureKind.mlsControlMissing);

    // More wakes do not fetch the event again.
    final syncCalls = api.syncCalls;
    final fetches = api.mlsMessageCalls;
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.settle();
    expect(api.syncCalls, syncCalls);
    expect(api.mlsMessageCalls, fetches);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('the recovery record survives a restart', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveSyncRecovery(SyncRecovery(
      kind: SyncFailureKind.mlsState,
      recordedAt: DateTime.utc(2026, 9, 24),
      eventId: 9,
    ));
    final api = _ScriptedApi();
    final harness = await _Harness.start(api, store: store);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsState);
    expect(api.syncCalls, 0);
    harness.dispose();
  });

  test('a malformed MLS control event stops sync at that event', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _projectionEvent(3),
        SyncEvent(
          id: 4,
          type: 'mls.message.created',
          conversationId: 'conv_1',
          payload: const <String, Object?>{},
          createdAt: DateTime.utc(2026, 9, 24),
        ),
        _projectionEvent(5),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(
        harness.state.syncRecovery!.kind, SyncFailureKind.mlsControlMalformed);
    expect(await harness.store.loadSyncCursor(), 3);
    harness.dispose();
  });

  test('an MLS message for another event is treated as malformed', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(6, 'mls_1')]
      ..mlsEventIdOverride['mls_1'] = 99;
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(
        harness.state.syncRecovery!.kind, SyncFailureKind.mlsControlMalformed);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('a rejected MLS commit is an MLS state failure and can be retried',
      () async {
    final api = _ScriptedApi()..events = <SyncEvent>[_mlsEvent(2, 'mls_bad')];
    final harness = await _Harness.start(api);
    harness.crypto.rejectedMls.add('mls_bad');
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsState);
    expect(harness.state.syncRecovery!.choices,
        contains(SyncRecoveryChoice.retry));
    expect(await harness.store.loadSyncCursor(), 0);

    harness.crypto.rejectedMls.clear();
    await harness.state.retrySyncRecovery();
    await harness.waitFor(() async => await harness.store.loadSyncCursor() == 2);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncRecovery(), isNull);
    expect(harness.state.deviceRecoveryRequired, isFalse);
    harness.dispose();
  });

  test('an expired application message follows the tombstone policy',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _envelopeEvent(4, 'msg_expired',
            ciphertext: _undecryptable,
            expiresAt: DateTime.utc(2000)),
        _envelopeEvent(5, 'msg_ok'),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() async => await harness.store.loadSyncCursor() == 5);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.hasProcessedMlsMessage('expired:4:msg_expired'),
        isTrue);
    expect(harness.crypto.applied, <String>['msg_ok']);
    harness.dispose();
  });

  test('a server-proven expired legacy envelope is tombstoned', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_envelopeEvent(4, 'msg_old', inline: false)]
      ..expiredEnvelopes.add('msg_old');
    final harness = await _Harness.start(api);
    await harness.waitFor(() async => await harness.store.loadSyncCursor() == 4);
    expect(harness.state.syncRecovery, isNull);
    expect(harness.crypto.applied, isEmpty);
    harness.dispose();
  });

  test('an undecryptable live message stops sync instead of being skipped',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _envelopeEvent(4, 'msg_bad', ciphertext: _undecryptable),
        _envelopeEvent(5, 'msg_ok'),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind,
        SyncFailureKind.applicationUndecryptable);
    expect(await harness.store.loadSyncCursor(), 0);
    expect(harness.crypto.applied, isEmpty);
    harness.dispose();
  });

  test('a missing legacy envelope without proof of expiry stops sync',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_envelopeEvent(4, 'msg_gone', inline: false)];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(
        harness.state.syncRecovery!.kind, SyncFailureKind.applicationMissing);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('a network failure keeps the cursor and is retried, not recorded',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..networkDown = true;
    final harness = await _Harness.start(api);
    await harness.waitFor(
        () => harness.state.connectionStatus == ConnectionStatus.offline);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncRecovery(), isNull);
    expect(await harness.store.loadSyncCursor(), 0);

    api.networkDown = false;
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() async => await harness.store.loadSyncCursor() == 5);
    expect(harness.state.connectionStatus, ConnectionStatus.online);
    harness.dispose();
  });

  test('a network failure while fetching MLS messages is not recorded',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..mlsNetworkDown = true;
    final harness = await _Harness.start(api);
    await harness.waitFor(
        () => harness.state.connectionStatus == ConnectionStatus.offline);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('a rejected token signs out without a recovery record', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..syncStatus = 401;
    final harness = await _Harness.start(api);
    await harness.waitFor(() => !harness.state.connected);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncRecovery(), isNull);
    expect((await harness.store.loadSession())!.deviceId, 'dev_me');
    harness.dispose();
  });

  test('an expired cursor asks for relink or backup, never a jump', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveSyncCursor(10);
    final api = _ScriptedApi()..syncStatus = 409;
    final harness = await _Harness.start(api, store: store);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    final recovery = harness.state.syncRecovery!;
    expect(recovery.kind, SyncFailureKind.cursorExpired);
    expect(recovery.choices, isNot(contains(SyncRecoveryChoice.retry)));
    expect(recovery.choices, contains(SyncRecoveryChoice.relink));
    expect(await store.loadSyncCursor(), 10);

    // Retry is not offered, so it does nothing.
    await harness.state.retrySyncRecovery();
    expect(harness.state.syncRecovery, isNotNull);
    expect(() => harness.state.relinkAfterSyncRecovery(confirmed: false),
        throwsArgumentError);
    await harness.state.relinkAfterSyncRecovery(confirmed: true);
    expect(harness.state.connected, isFalse);
    expect(await store.loadSession(), isNull);
    expect(await store.loadSyncRecovery(), isNull);
    harness.dispose();
  });

  test('a reconnect burst fetches MLS messages in one bounded request',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        for (var id = 1; id <= 40; id++)
          if (id.isEven) _mlsEvent(id, 'mls_$id') else _projectionEvent(id),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() async => await harness.store.loadSyncCursor() == 40);
    expect(api.mlsListCalls, 1);
    expect(api.mlsMessageCalls, 0);
    expect(harness.crypto.processedMls, hasLength(20));
    expect(harness.crypto.processedMls.toSet(), hasLength(20));
    harness.dispose();
  });

  test('an unknown event type stops sync as unsupported', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        SyncEvent(
          id: 3,
          type: 'future.event',
          createdAt: DateTime.utc(2026, 9, 24),
        ),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind, SyncFailureKind.unsupportedEvent);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('recovery records round-trip and reject damaged values', () {
    final recovery = SyncRecovery(
      kind: SyncFailureKind.applicationMissing,
      recordedAt: DateTime.utc(2026, 9, 24, 12),
      eventId: 7,
      eventType: 'message.envelope.created',
      conversationId: 'conv_1',
    );
    final decoded = SyncRecovery.decode(recovery.encode())!;
    expect(decoded.kind, recovery.kind);
    expect(decoded.eventId, 7);
    expect(decoded.conversationId, 'conv_1');
    expect(decoded.recordedAt, recovery.recordedAt);
    expect(SyncRecovery.decode('{"kind":"nope"}'), isNull);
    expect(SyncRecovery.decode('not json'), isNull);
    expect(SyncRecovery.decode(null), isNull);
  });
}

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);

const _undecryptable = <int>[0];

SyncEvent _mlsEvent(int id, String messageId) => SyncEvent(
      id: id,
      type: 'mls.message.created',
      conversationId: 'conv_1',
      payload: <String, Object?>{'mls_message_id': messageId},
      createdAt: DateTime.utc(2026, 9, 24),
    );

SyncEvent _projectionEvent(int id) => SyncEvent(
      id: id,
      type: 'read_receipt.updated',
      conversationId: 'conv_1',
      payload: const <String, Object?>{},
      createdAt: DateTime.utc(2026, 9, 24),
    );

SyncEvent _envelopeEvent(
  int id,
  String messageId, {
  List<int> ciphertext = const <int>[1],
  DateTime? expiresAt,
  bool inline = true,
}) =>
    SyncEvent(
      id: id,
      type: 'message.envelope.created',
      conversationId: 'conv_1',
      payload: <String, Object?>{
        'message_id': messageId,
        'conversation_id': 'conv_1',
        if (inline)
          'envelope': _envelope(messageId,
                  ciphertext: ciphertext, expiresAt: expiresAt)
              .toJson(),
      },
      createdAt: DateTime.utc(2026, 9, 24),
    );

ReceivedMessageEnvelope _envelope(
  String id, {
  List<int> ciphertext = const <int>[1],
  DateTime? expiresAt,
}) =>
    ReceivedMessageEnvelope(
      id: id,
      conversationId: 'conv_1',
      senderAccountId: 'acct_peer',
      senderDeviceId: 'dev_peer',
      idempotencyKey: 'idem_$id',
      ciphertext: ciphertext,
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: DateTime.utc(2026, 9, 24),
      expiresAt: expiresAt,
    );

class _Harness {
  _Harness(this.state, this.store, this.crypto);

  final AppState state;
  final MemoryLocalStore store;
  final _FakeMlsCrypto crypto;

  static Future<_Harness> start(_ScriptedApi api,
      {MemoryLocalStore? store}) async {
    final local = store ?? MemoryLocalStore();
    if (store == null) await local.saveSession(_session);
    final crypto = _FakeMlsCrypto(local);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: local,
      syncServiceFactory: (_, __) => _QuietSync(),
    );
    await state.tryRestoreSession();
    return _Harness(state, local, crypto);
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitFor(FutureOr<bool> Function() condition) async {
    for (var attempt = 0; attempt < 400; attempt++) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('condition not reached');
  }

  void dispose() => state.dispose();
}

class _ScriptedApi extends ApiClient {
  _ScriptedApi() : super(baseUrl: 'https://localhost:8080');

  List<SyncEvent> events = <SyncEvent>[];
  final Set<String> mlsMissing = <String>{};
  final Set<String> expiredEnvelopes = <String>{};
  final Map<String, int> mlsEventIdOverride = <String, int>{};
  bool networkDown = false;
  bool mlsNetworkDown = false;
  int? syncStatus;
  int syncCalls = 0;
  int mlsListCalls = 0;
  int mlsMessageCalls = 0;

  MlsMessage _message(String id, int eventId) => MlsMessage(
        id: id,
        conversationId: 'conv_1',
        senderAccountId: 'acct_peer',
        senderDeviceId: 'dev_peer',
        kind: 'commit',
        payload: const <int>[1],
        idempotencyKey: 'idem_$id',
        syncEventId: mlsEventIdOverride[id] ?? eventId,
        createdAt: DateTime.utc(2026, 9, 24),
      );

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

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
    if (networkDown) throw const SocketException('offline');
    final status = syncStatus;
    if (status == 401) throw ApiException(401, '{"error":"unauthorized"}');
    if (status == 409) {
      throw ApiException(409, '{"error":"device_recovery_required"}');
    }
    return events
        .where((event) => event.id > after)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<List<MlsMessage>> mlsMessages(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    mlsListCalls++;
    if (mlsNetworkDown) throw const SocketException('offline');
    return <MlsMessage>[
      for (final event in events)
        if (event.type == 'mls.message.created' && event.id > after)
          if ((event.payload as Map)['mls_message_id'] case final String id
              when !mlsMissing.contains(id))
            _message(id, event.id),
    ].take(limit).toList(growable: false);
  }

  @override
  Future<MlsMessage> mlsMessage(String token, String messageId) async {
    mlsMessageCalls++;
    if (mlsNetworkDown) throw const SocketException('offline');
    if (mlsMissing.contains(messageId)) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    final event = events.firstWhere((event) =>
        event.type == 'mls.message.created' &&
        (event.payload as Map)['mls_message_id'] == messageId);
    return _message(messageId, event.id);
  }

  @override
  Future<ReceivedMessageEnvelope> message(
      String token, String messageId) async {
    if (expiredEnvelopes.contains(messageId)) {
      throw ApiException(410, '{"error":"message_expired"}');
    }
    throw ApiException(404, '{"error":"not_found"}');
  }
}

class _FakeMlsCrypto implements MlsConversationCryptoService {
  _FakeMlsCrypto(this.store);

  final MemoryLocalStore store;
  final Set<String> rejectedMls = <String>{};
  final List<String> processedMls = <String>[];
  final List<String> applied = <String>[];

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<void> processMlsMessage(MlsMessage message) async {
    final marker = 'mls:${message.syncEventId}:${message.id}';
    if (await store.hasProcessedMlsMessage(marker)) return;
    if (rejectedMls.contains(message.id)) {
      throw StateError('commit rejected');
    }
    processedMls.add(message.id);
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: marker,
      conversationId: message.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: message.syncEventId,
    ));
  }

  @override
  Future<List<int>?> processApplicationMessage(
      ReceivedMessageEnvelope envelope, int syncEventId) async {
    if (envelope.ciphertext.length == 1 && envelope.ciphertext.first == 0) {
      throw StateError('decryption failed');
    }
    applied.add(envelope.id);
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'application:$syncEventId:${envelope.id}',
      conversationId: envelope.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: syncEventId,
    ));
    return null;
  }

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
  void dispose() => _controller.close();
}
