import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// D70 S4 app wiring: expired key packages are pruned after a caught-up
/// pass (throttled), leaving a conversation drops its MLS group (only on
/// the user's leave, and only after the server took it) and its unsent
/// messages, and a record over its size limit (native -8) stops sync with
/// a localized message and an offer to leave that conversation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a caught-up pass prunes key packages, at most once per interval',
      () async {
    final api = _ScriptedApi()..events = <SyncEvent>[_envelopeEvent(4, 'm1')];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.lastSyncedAt != null);
    expect(harness.crypto.prunes, 1);

    final passes = api.syncCalls;
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() => api.syncCalls > passes);
    await harness.waitFor(() => harness.state.syncError == null);
    await harness.settle();
    expect(harness.crypto.prunes, 1);
    harness.dispose();
  });

  test('a failed prune never stops sync', () async {
    final api = _ScriptedApi()..events = <SyncEvent>[_envelopeEvent(4, 'm1')];
    final harness = await _Harness.start(api,
        configure: (crypto) => crypto.pruneError = StateError('prune'));
    await harness.waitFor(() => harness.state.lastSyncedAt != null);
    expect(harness.crypto.prunes, 1);
    expect(harness.state.syncRecovery, isNull);
    expect(harness.state.syncError, isNull);
    harness.dispose();
  });

  test('leaving drops the group and that conversation\'s unsent messages',
      () async {
    final api = _ScriptedApi()..events = <SyncEvent>[_envelopeEvent(4, 'm1')];
    final harness = await _Harness.start(api);
    final state = harness.state;
    await harness.waitFor(() => state.lastSyncedAt != null);
    expect(harness.crypto.deleted, isEmpty);
    await harness.store.enqueueEnvelope(_outgoing('conv_1', 'out_1'));
    await harness.store.enqueueEnvelope(_outgoing('conv_2', 'out_2'));

    expect(await state.leaveConversation('conv_1'), isTrue);
    expect(api.left, <String>['conv_1']);
    // The group goes in the next pass, before it reads events.
    await harness.waitFor(() => harness.crypto.deleted.isNotEmpty);
    expect(harness.crypto.deleted, <String>['conv_1']);
    expect(
        (await harness.store.pendingEnvelopes()).map((e) => e.idempotencyKey),
        <String>['out_2']);
    // Done once: later passes do not delete it again.
    await harness.waitFor(() async =>
        !(await harness.store.loadSetting('mls.left_conversations') ?? '')
            .contains('conv_1'));
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() => state.syncError == null);
    await harness.settle();
    expect(harness.crypto.deleted, <String>['conv_1']);
    harness.dispose();
  });

  test('a failed group drop is tried again by the next pass', () async {
    final api = _ScriptedApi();
    final harness = await _Harness.start(api,
        configure: (crypto) => crypto.deleteFailures = 1);
    await harness.waitFor(() => harness.state.lastSyncedAt != null);
    expect(await harness.state.leaveConversation('conv_1'), isTrue);
    await harness.waitFor(() => harness.crypto.deleteAttempts == 1);
    expect(harness.crypto.deleted, isEmpty);
    // Sync was not stopped by it.
    await harness.waitFor(() => harness.state.syncError == null);
    expect(harness.state.syncRecovery, isNull);

    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() => harness.crypto.deleted.isNotEmpty);
    expect(harness.crypto.deleted, <String>['conv_1']);
    harness.dispose();
  });

  test('a Welcome after a leave clears the note, so the new group stays',
      () async {
    final api = _ScriptedApi();
    final harness = await _Harness.start(api,
        configure: (crypto) => crypto.deleteFailures = 2);
    final state = harness.state;
    await harness.waitFor(() => state.lastSyncedAt != null);
    expect(await state.leaveConversation('conv_1'), isTrue);
    await harness.waitFor(() => harness.crypto.deleteAttempts == 1);

    // Added back: the next pass still tries the old group first (and
    // fails again here), then applies the Welcome.
    api.events = <SyncEvent>[_welcomeEvent(4, 'conv_1')];
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 4);
    expect(harness.crypto.joined, <String>['conv_1']);
    expect(harness.crypto.deleteAttempts, 2);
    expect(await harness.store.loadSetting('mls.left_conversations'),
        isNot(contains('conv_1')));

    // Later passes leave the joined group alone.
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() => state.syncError == null);
    await harness.settle();
    expect(harness.crypto.deleteAttempts, 2);
    expect(harness.crypto.deleted, isEmpty);
    harness.dispose();
  });

  test('a leave the server refuses keeps the group', () async {
    final api = _ScriptedApi()..refuseLeave = true;
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.lastSyncedAt != null);
    expect(await harness.state.leaveConversation('conv_1'), isFalse);
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.waitFor(() => harness.state.syncError == null);
    await harness.settle();
    expect(harness.crypto.deleted, isEmpty);
    expect(await harness.store.loadSetting('mls.left_conversations'), isNull);
    harness.dispose();
  });

  test('a group over its size limit stops sync and offers to leave it',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _envelopeEvent(4, 'm_big'),
        _envelopeEvent(5, 'm_other', conversationId: 'conv_2'),
      ];
    final harness = await _Harness.start(api,
        configure: (crypto) => crypto.applyErrors['m_big'] =
            const CryptoRecordLimitExceeded(conversationId: 'conv_1'));
    final state = harness.state;
    await harness.waitFor(() => state.syncRecovery != null);
    final recovery = state.syncRecovery!;
    expect(recovery.kind, SyncFailureKind.recordLimit);
    expect(recovery.conversationId, 'conv_1');
    expect(recovery.eventId, 4);
    expect(recovery.choices, contains(SyncRecoveryChoice.leaveConversation));
    expect(state.syncError, state.l10n.syncErrorRecordLimit);
    // Fail closed: nothing after the stopped event was applied.
    expect(await harness.store.loadSyncCursor(), 0);
    expect(harness.crypto.applied, <String>['m_big']);
    // The record survives a restart.
    expect((await harness.store.loadSyncRecovery())!.kind,
        SyncFailureKind.recordLimit);

    // Leaving needs confirmation.
    expect(() => state.leaveConversationAfterSyncRecovery(confirmed: false),
        throwsArgumentError);
    // The server no longer sends the left conversation's events.
    api.onLeave = (id) => api.events = api.events
        .where((event) => event.conversationId != id)
        .toList(growable: false);
    expect(await state.leaveConversationAfterSyncRecovery(confirmed: true),
        isTrue);
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 5);
    await harness.waitFor(() => state.syncRecovery == null);
    expect(harness.crypto.deleted, <String>['conv_1']);
    expect(harness.crypto.applied, <String>['m_big', 'm_other']);
    expect(await harness.store.loadSyncRecovery(), isNull);
    harness.dispose();
  });

  test('the device record over its limit offers no leave', () async {
    final api = _ScriptedApi()..events = <SyncEvent>[_envelopeEvent(4, 'm1')];
    final harness = await _Harness.start(api,
        configure: (crypto) =>
            crypto.applyErrors['m1'] = const CryptoRecordLimitExceeded());
    final state = harness.state;
    await harness.waitFor(() => state.syncRecovery != null);
    expect(state.syncRecovery!.kind, SyncFailureKind.recordLimit);
    expect(state.syncRecovery!.conversationId, isNull);
    expect(state.syncRecovery!.choices,
        isNot(contains(SyncRecoveryChoice.leaveConversation)));
    expect(state.syncError, state.l10n.syncErrorRecordLimitDevice);
    expect(await state.leaveConversationAfterSyncRecovery(confirmed: true),
        isFalse);
    expect(api.left, isEmpty);
    harness.dispose();
  });

  test('a record over its limit reads as a localized message', () {
    final locales = <Locale>[
      const Locale('en'),
      const Locale('sr'),
      const Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn'),
    ];
    final seen = <String>{};
    for (final locale in locales) {
      final l10n = lookupAppLocalizations(locale);
      final group = describeError(
          const CryptoRecordLimitExceeded(conversationId: 'conv_1'),
          l10n,
          false);
      final device =
          describeError(const CryptoRecordLimitExceeded(), l10n, false);
      expect(group, l10n.errorConversationTooLarge);
      expect(device, l10n.errorCryptoRecordLimit);
      expect(group, isNot(l10n.errorGeneric));
      expect(seen.add(group), isTrue, reason: '$locale');
      final recovery = SyncRecovery(
        kind: SyncFailureKind.recordLimit,
        recordedAt: DateTime.utc(2026, 11, 1),
        eventId: 4,
        conversationId: 'conv_1',
      );
      expect(recovery.localizedMessage(l10n), l10n.syncErrorRecordLimit);
      // The record round-trips.
      expect(SyncRecovery.decode(recovery.encode())!.kind,
          SyncFailureKind.recordLimit);
    }
    // The message names no id, and neither does the exception's text.
    expect(
        const CryptoRecordLimitExceeded(conversationId: 'conv_secret')
            .toString(),
        isNot(contains('conv_secret')));
  });

  test('the native error maps to the app error, naming only a group', () {
    expect(
        recordLimitFromNative(NativeRecordLimitException(2, 'conv_1'.codeUnits))
            .conversationId,
        'conv_1');
    expect(
        recordLimitFromNative(const NativeRecordLimitException(1, <int>[]))
            .conversationId,
        isNull);
    expect(
        recordLimitFromNative(const NativeRecordLimitException(3, <int>[7, 8]))
            .conversationId,
        isNull);
  });
}

MessageEnvelope _outgoing(String conversationId, String key) => MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: key,
      ciphertext: const <int>[1, 2, 3],
      cryptoProtocol: 'mls10-openmls-v1',
    );

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);

SyncEvent _envelopeEvent(int id, String messageId,
        {String conversationId = 'conv_1'}) =>
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
          ciphertext: const <int>[1],
          cryptoProtocol: 'mls10-openmls-v1',
          createdAt: DateTime.utc(2026, 9, 24, 0, 0, id),
        ).toJson(),
      },
      createdAt: DateTime.utc(2026, 9, 24),
    );

SyncEvent _welcomeEvent(int id, String conversationId) => SyncEvent(
      id: id,
      type: 'mls.message.created',
      conversationId: conversationId,
      payload: <String, Object?>{'mls_message_id': 'mls_$id'},
      createdAt: DateTime.utc(2026, 9, 24),
    );

class _Harness {
  _Harness(this.state, this.store, this.crypto);

  final AppState state;
  final LocalStore store;
  final _FakeMlsCrypto crypto;

  static Future<_Harness> start(_ScriptedApi api,
      {void Function(_FakeMlsCrypto crypto)? configure}) async {
    final local = MemoryLocalStore();
    await local.saveSession(_session);
    final crypto = _FakeMlsCrypto(local);
    configure?.call(crypto);
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
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    fail('condition not reached');
  }

  void dispose() => state.dispose();
}

class _ScriptedApi extends ApiClient {
  _ScriptedApi() : super(baseUrl: 'https://localhost:8080');

  List<SyncEvent> events = <SyncEvent>[];
  int syncCalls = 0;
  bool refuseLeave = false;
  final List<String> left = <String>[];
  void Function(String conversationId)? onLeave;

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        for (final id in <String>['conv_1', 'conv_2'])
          if (!left.contains(id)) Conversation(id: id, kind: 'group'),
      ];

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
    return events
        .where((event) => event.id > after)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<void> removeConversationMember(
      String token, String conversationId, String accountId) async {
    if (refuseLeave) throw ApiException(403, '{"error":"forbidden"}');
    expect(accountId, 'me');
    left.add(conversationId);
    onLeave?.call(conversationId);
  }

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async =>
      throw ApiException(503, '{"error":"unavailable"}');

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
        kind: 'welcome',
        payload: const <int>[1],
        idempotencyKey: 'idem_${event.id}',
        syncEventId: event.id,
        createdAt: DateTime.utc(2026, 9, 24),
        recipientDeviceId: _session.deviceId,
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

class _FakeMlsCrypto
    implements MlsConversationCryptoService, MlsStateMaintenanceCryptoService {
  _FakeMlsCrypto(this.store);

  final LocalStore store;
  final List<String> applied = <String>[];
  final Map<String, Object> applyErrors = <String, Object>{};
  final List<String> deleted = <String>[];
  int deleteAttempts = 0;
  int deleteFailures = 0;
  int prunes = 0;
  Object? pruneError;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<List<int>?> processApplicationMessage(
      ReceivedMessageEnvelope envelope, int syncEventId) async {
    applied.add(envelope.id);
    final error = applyErrors.remove(envelope.id);
    if (error != null) throw error;
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'application:$syncEventId:${envelope.id}',
      conversationId: envelope.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: syncEventId,
    ));
    return null;
  }

  final List<String> joined = <String>[];

  @override
  Future<void> processMlsMessage(MlsMessage message) async {
    joined.add(message.conversationId);
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'mls:${message.syncEventId}:${message.id}',
      conversationId: message.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: message.syncEventId,
    ));
  }

  @override
  Future<int> pruneExpiredKeyPackages(DateTime now) async {
    prunes++;
    final error = pruneError;
    if (error != null) throw error;
    return 0;
  }

  @override
  Future<bool> deleteConversationState(String conversationId) async {
    deleteAttempts++;
    if (deleteFailures > 0) {
      deleteFailures--;
      throw StateError('delete');
    }
    deleted.add(conversationId);
    return true;
  }

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      null;

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
