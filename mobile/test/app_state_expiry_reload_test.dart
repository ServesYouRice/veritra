// TASK-053: when the expiry purge deleted rows but the history reload then
// fails, no expired text stays in the chat and the reload is retried even
// with nothing else left to expire.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_own',
  deviceId: 'dev_own',
);

LocalMessage _row(String id, String body, {DateTime? expiresAt}) =>
    LocalMessage(
      key: 'dev_peer:$id',
      conversationId: 'conv_1',
      senderAccountId: 'acct_peer',
      senderDeviceId: 'dev_peer',
      kind: LocalMessageKind.text,
      body: body,
      createdAt: DateTime.utc(2026, 10, 24).millisecondsSinceEpoch,
      state: LocalMessageState.received,
      expiresAt: expiresAt?.toUtc().millisecondsSinceEpoch,
    );

/// Local history rows held in a list; reloading them can be made to fail.
class _HistoryStore extends MemoryLocalStore {
  List<LocalMessage> rows = <LocalMessage>[];
  bool failLoads = false;
  int loads = 0;

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) async {
    loads++;
    if (failLoads) throw StateError('database busy');
    return rows.where((r) => r.conversationId == conversationId).toList();
  }

  @override
  Future<Set<String>> purgeExpiredMessages({DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final touched = <String>{
      for (final r in rows)
        if (r.expiresAt != null && r.expiresAt! <= at) r.conversationId,
    };
    rows = rows.where((r) => r.expiresAt == null || r.expiresAt! > at).toList();
    return touched;
  }

  @override
  Future<DateTime?> nextMessageExpiry() async {
    int? next;
    for (final r in rows) {
      final at = r.expiresAt;
      if (at != null && (next == null || at < next)) next = at;
    }
    return next == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(next, isUtc: true);
  }
}

class _HistoryMls implements MlsConversationCryptoService {
  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _IdleSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed reload after the purge hides expired text and retries',
      () async {
    final soon = DateTime.now().toUtc().add(const Duration(milliseconds: 300));
    final store = _HistoryStore()
      ..rows = <LocalMessage>[
        _row('soon', 'soon text', expiresAt: soon),
        _row('live', 'live text'),
      ];
    final api = ApiClient(baseUrl: 'https://localhost:8080');
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: _HistoryMls(),
      localStore: store,
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..api = api
      ..session = _session
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group', createdBy: 'acct_own'),
      ];
    addTearDown(state.dispose);
    await state.refreshHistory('conv_1');
    expect(state.timelineFor('conv_1').map((e) => e.id),
        unorderedEquals(<String>['dev_peer:soon', 'dev_peer:live']));

    await Future<void>.delayed(const Duration(milliseconds: 400));
    store.failLoads = true;
    var notified = 0;
    state.addListener(() => notified++);
    await state.purgeExpiredMessages();

    expect(store.rows.map((r) => r.key), <String>['dev_peer:live'],
        reason: 'the database delete itself worked');
    expect(
        state.timelineFor('conv_1').map((e) => e.id), <String>['dev_peer:live'],
        reason: 'expired text is still in the chat after a failed reload');
    expect(state.historyFor('conv_1').forKey('dev_peer:soon'), isNull,
        reason: 'replies, pins and starred read the cached history too');
    expect(notified, greaterThan(0));
    expect(await store.nextMessageExpiry(), isNull);

    // Nothing is left to expire, yet the failed reload is tried again.
    store.failLoads = false;
    final loadsBefore = store.loads;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (store.loads == loadsBefore && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.loads, greaterThan(loadsBefore), reason: 'never retried');
    expect(state.historyFor('conv_1').messages.map((m) => m.body),
        <String?>['live text']);
  });
}
