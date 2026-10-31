// Periodic MLS self-update in AppState: a due conversation gets one staged
// update-only commit in a foreground pass, through the D28 staged-commit
// path; a pending revocation or removal holds it back; a refusal drops it
// and backs off instead of pausing the conversation.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/mls_self_update_policy.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);
const _setting = '${MlsSelfUpdatePolicy.settingName}:dev_me';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('100 sent messages stage one update that the server accepts', () async {
    final store = await _storeWith(_countDue('conv_a'));
    final api = _Api();
    final crypto = _Crypto(store);
    final state = await _start(api, store, crypto);

    await _waitFor(() => crypto.completed.contains('conv_a'));
    expect(crypto.staged, ['conv_a']);
    final sent = api.bundles.single;
    expect(sent.isUpdateOnly, isTrue);
    expect(sent.added, isEmpty);
    expect(sent.removed, isEmpty);
    expect(await store.pendingMlsMessages(), isEmpty);
    // The count starts over from the accepted update.
    await _waitFor(() async => !(await _saved(store)).contains('"sent"'));
    final record = _record(await _saved(store), 'conv_a');
    expect(
        DateTime.now().toUtc().difference(_at(record['last'])).inMinutes.abs(),
        lessThan(2));
    state.dispose();
  });

  test('a conversation with a pending revocation is not updated', () async {
    final store = await _storeWith(_countDue('conv_a'));
    final api = _Api()
      ..revocations = <MlsRevocation>[
        MlsRevocation(
          conversationId: 'conv_a',
          revokedDeviceId: 'dev_gone',
          revokedAccountId: 'acct_other',
          coordinatorDeviceId: 'dev_other',
          state: 'pending',
          requestedAt: DateTime.now().toUtc(),
        ),
      ];
    final crypto = _Crypto(store);
    final state = await _start(api, store, crypto);
    await _waitFor(() => api.revocationReads >= 1 && api.pendingReads >= 1);
    await _settle();
    expect(crypto.staged, isEmpty);
    state.dispose();
  });

  test('a conversation with a pending removal is not updated', () async {
    final store = await _storeWith(_countDue('conv_a'));
    final api = _Api()
      ..pending = <MlsPendingChange>[
        const MlsPendingChange(
          conversationId: 'conv_a',
          epoch: 3,
          add: <MlsDeviceRef>[],
          remove: <MlsDeviceRef>[(accountId: 'acct_x', deviceId: 'dev_x')],
          coordinatorDeviceId: 'dev_other',
        ),
      ];
    final crypto = _Crypto(store);
    final state = await _start(api, store, crypto);
    await _waitFor(() => api.pendingReads >= 2);
    await _settle();
    expect(crypto.staged, isEmpty);
    state.dispose();
  });

  test('a lost epoch race drops the update and retries after a back-off',
      () async {
    final store = await _storeWith(_countDue('conv_a'));
    final api = _Api()
      ..failures.add(ApiException(409, '{"error":"mls_epoch_conflict"}'));
    final crypto = _Crypto(store);
    final state = await _start(api, store, crypto);

    await _waitFor(() => crypto.abandoned.contains('conv_a'));
    expect(await store.pendingMlsMessages(), isEmpty);
    expect(state.mlsConversationFailed('conv_a'), isFalse);
    await _waitFor(() async => (await _saved(store)).contains('not_before'));
    final wait = _at(_record(await _saved(store), 'conv_a')['not_before'])
        .difference(DateTime.now().toUtc());
    expect(wait, greaterThan(const Duration(minutes: 9)));
    expect(wait, lessThanOrEqualTo(const Duration(minutes: 15)));
    // Nothing more within the back-off, however many passes run.
    state.handleAppLifecycleState(AppLifecycleState.paused);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await _waitFor(() => api.revocationReads >= 2);
    await _settle();
    expect(crypto.staged, ['conv_a']);
    state.dispose();

    // Once the back-off has passed, the next run updates and lands.
    await _rewrite(store, (record) => record.remove('not_before'));
    final again = _Crypto(store);
    final restarted = await _start(_Api(), store, again);
    await _waitFor(() => again.completed.contains('conv_a'));
    restarted.dispose();
  });

  for (final (name, error, minimum) in <(String, ApiException, Duration)>[
    (
      'the self-update budget',
      ApiException(429, '{"error":"mls_self_update_limit"}'),
      MlsSelfUpdatePolicy.minInterval,
    ),
    (
      'an older server',
      ApiException(400, '{"error":"invalid_input"}'),
      MlsSelfUpdatePolicy.refusedBackoff,
    ),
  ]) {
    test('a refusal by $name drops the update without pausing the chat',
        () async {
      final store = await _storeWith(_countDue('conv_a'));
      final api = _Api()..failures.add(error);
      final crypto = _Crypto(store);
      final state = await _start(api, store, crypto);
      await _waitFor(() => crypto.abandoned.contains('conv_a'));
      expect(await store.pendingMlsMessages(), isEmpty);
      expect(state.mlsConversationFailed('conv_a'), isFalse);
      await _waitFor(() async => (await _saved(store)).contains('not_before'));
      final wait = _at(_record(await _saved(store), 'conv_a')['not_before'])
          .difference(DateTime.now().toUtc());
      expect(wait, greaterThan(minimum - const Duration(minutes: 1)));
      expect(wait, lessThanOrEqualTo(minimum * 1.5));
      state.dispose();
    });
  }

  test('a Welcome records the join; the update waits for its delay', () async {
    final store = await _storeWith(null);
    final api = _Api()
      ..events = <SyncEvent>[
        SyncEvent(
          id: 1,
          type: 'mls.message.created',
          conversationId: 'conv_a',
          payload: const <String, Object?>{
            'mls_message_id': 'mls_welcome',
            'kind': 'welcome',
          },
          createdAt: DateTime.now().toUtc(),
        ),
      ];
    final crypto = _Crypto(store);
    final state = await _start(api, store, crypto);
    await _waitFor(() => crypto.processed.contains('mls_welcome'));
    await _waitFor(() async =>
        (await _saved(store)).contains('"joined"') &&
        !_record(await _saved(store), 'conv_a').containsKey('last'));
    // Not at once: at least the join delay passes first.
    expect(crypto.staged, isEmpty);
    state.dispose();

    // After the delay the next pass updates the newly joined group.
    await _rewrite(
        store,
        (record) => record['joined'] = DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch);
    final again = _Crypto(store);
    final restarted = await _start(_Api(), store, again);
    await _waitFor(() => again.completed.contains('conv_a'));
    restarted.dispose();
  });

  test('a crypto service without self-update is never asked', () async {
    final store = await _storeWith(_countDue('conv_a'));
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: _PlainCrypto(),
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
    );
    await state.tryRestoreSession();
    await _waitFor(() => api.revocationReads >= 1);
    await _settle();
    expect(api.bundles, isEmpty);
    state.dispose();
  });
}

/// A saved policy in which [conversationId] reached the count trigger.
String _countDue(String conversationId) {
  final policy = MlsSelfUpdatePolicy(accountId: 'acct_me', deviceId: 'dev_me')
    ..recordPathCommit(conversationId,
        DateTime.now().toUtc().subtract(const Duration(hours: 2)))
    ..recordPathCommit('conv_b', DateTime.now().toUtc());
  for (var i = 0; i < MlsSelfUpdatePolicy.messageThreshold; i++) {
    policy.recordSent(conversationId);
  }
  return policy.encode();
}

Future<MemoryLocalStore> _storeWith(String? policy) async {
  final store = MemoryLocalStore();
  await store.saveSession(_session);
  await store.saveCryptoState(
      StoredCryptoState(
          counter: 1, stateKey: List<int>.filled(32, 1), sealedState: [1]),
      0);
  if (policy != null) await store.saveSetting(_setting, policy);
  return store;
}

Future<String> _saved(LocalStore store) async =>
    await store.loadSetting(_setting) ?? '';

Map<String, Object?> _record(String raw, String conversationId) =>
    Map<String, Object?>.from(
        ((jsonDecode(raw) as Map)['groups'] as Map)[conversationId] as Map);

DateTime _at(Object? millis) =>
    DateTime.fromMillisecondsSinceEpoch(millis! as int, isUtc: true);

/// Edits the saved record of conv_a, as the passing of time would.
Future<void> _rewrite(
    LocalStore store, void Function(Map<String, Object?> record) edit) async {
  final json = jsonDecode(await _saved(store)) as Map<String, Object?>;
  final groups = Map<String, Object?>.from(json['groups'] as Map);
  final record = Map<String, Object?>.from(groups['conv_a'] as Map);
  edit(record);
  groups['conv_a'] = record;
  json['groups'] = groups;
  await store.saveSetting(_setting, jsonEncode(json));
}

Future<AppState> _start(
    _Api api, MemoryLocalStore store, _Crypto crypto) async {
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: crypto,
    localStore: store,
    syncServiceFactory: (_, __) => _QuietSync(),
  );
  state.handleAppLifecycleState(AppLifecycleState.resumed);
  await state.tryRestoreSession();
  return state;
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> _waitFor(FutureOr<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not reached');
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  final List<MlsCommitBundle> bundles = <MlsCommitBundle>[];
  final List<Object> failures = <Object>[];
  List<MlsRevocation> revocations = <MlsRevocation>[];
  List<MlsPendingChange> pending = <MlsPendingChange>[];
  List<SyncEvent> events = <SyncEvent>[];
  int revocationReads = 0;
  int pendingReads = 0;

  @override
  void close() {}

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        Conversation(
            id: 'conv_a', kind: 'group', lastMessageAt: DateTime.now().toUtc()),
        Conversation(id: 'conv_b', kind: 'group'),
      ];

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      const <ConversationMember>[];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<SyncEvent>> syncEvents(String token,
      {int after = 0, int limit = 100}) async {
    final page = events.where((event) => event.id > after).toList();
    return page;
  }

  @override
  Future<List<MlsMessage>> mlsMessages(String token,
          {int after = 0, int limit = 100}) async =>
      <MlsMessage>[
        for (final event in events)
          if (event.id > after)
            MlsMessage(
              id: 'mls_welcome',
              conversationId: 'conv_a',
              senderAccountId: 'acct_other',
              senderDeviceId: 'dev_other',
              recipientDeviceId: 'dev_me',
              kind: 'welcome',
              payload: const <int>[7],
              idempotencyKey: 'welcome',
              syncEventId: event.id,
              createdAt: event.createdAt,
            ),
      ];

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async {
    revocationReads++;
    return revocations;
  }

  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async {
    pendingReads++;
    return pending;
  }

  @override
  Future<void> publishDeviceKeyPackages(String token, List<List<int>> packages,
      {Duration lifetime = const Duration(days: 30)}) async {}

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<int> sendMlsCommitBundle(
    String token,
    String conversationId, {
    required String idempotencyKey,
    required MlsCommitBundle bundle,
  }) async {
    if (failures.isNotEmpty) throw failures.removeAt(0);
    bundles.add(bundle);
    return bundle.epoch + 1;
  }
}

class _Crypto
    implements MlsConversationCryptoService, MlsSelfUpdateCryptoService {
  _Crypto(this.store);

  final MemoryLocalStore store;
  final List<String> staged = <String>[];
  final List<String> completed = <String>[];
  final List<String> abandoned = <String>[];
  final List<String> processed = <String>[];

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      (epoch: 3, pending: false);

  @override
  Future<void> stageSelfUpdate(String conversationId) async {
    staged.add(conversationId);
    final counter = (await store.loadCryptoState())!.counter;
    await store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
      expectedCounter: counter,
      expectedCursor: await store.loadSyncCursor(),
      state: StoredCryptoState(
          counter: counter + 1,
          stateKey: List<int>.filled(32, 1),
          sealedState: const <int>[1]),
      messages: <PendingMlsMessage>[
        PendingMlsMessage(
          idempotencyKey: 'update_${staged.length}',
          conversationId: conversationId,
          kind: MlsCommitBundle.kind,
          payload: const MlsCommitBundle(epoch: 3, commit: <int>[9]).encode(),
        ),
      ],
    ));
  }

  @override
  Future<void> completeCommitBundle(PendingMlsMessage bundle) async {
    completed.add(bundle.conversationId);
    await store.removePendingMlsMessage(bundle.idempotencyKey);
  }

  @override
  Future<void> abandonCommitBundle(PendingMlsMessage bundle) async {
    abandoned.add(bundle.conversationId);
    await store.removePendingMlsMessage(bundle.idempotencyKey);
  }

  @override
  Future<void> processMlsMessage(MlsMessage message) async {
    processed.add(message.id);
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'mls:${message.syncEventId}:${message.id}',
      conversationId: message.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: message.syncEventId,
    ));
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

/// An MLS service from before self-update: it has no stageSelfUpdate.
class _PlainCrypto implements MlsConversationCryptoService {
  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      (epoch: 3, pending: false);

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
