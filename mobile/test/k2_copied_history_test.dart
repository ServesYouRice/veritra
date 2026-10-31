import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/copied_history_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const origin = 'https://example.test';
const source = 'source';
final now = DateTime.now().millisecondsSinceEpoch;

const _session = Session(
    baseUrl: origin,
    token: 'receiver-token',
    accountId: 'alice',
    deviceId: 'receiver',
    deviceSecret: 'receiver-secret');

HistoryImportContext _context() => HistoryImportContext(
    origin: origin,
    accountId: 'alice',
    sourceDeviceId: source,
    recipientDeviceId: 'receiver',
    transferId: 'transfer',
    snapshotCounter: 1,
    snapshotCreatedAt: now,
    digest: 'a' * 64);

LocalMessage _message(String conversation, String action,
        {String? body,
        String sender = 'bob',
        int? expires,
        String kind = 'text'}) =>
    LocalMessage(
        key: '$source:$action',
        conversationId: conversation,
        senderAccountId: sender,
        senderDeviceId: source,
        kind: kind,
        body: body ?? action,
        createdAt: now - 1000,
        state: 'received',
        expiresAt: expires,
        senderHidden: false);

/// A copy holding one chat that is still live here ('live') and one this
/// device was never added to ('old').
List<int> _snapshot() => HistorySnapshot(
        accountId: 'alice',
        sourceDeviceId: source,
        counter: 1,
        createdAt: now,
        conversations: const [
          HistoryConversation('live', 'dm', title: 'Live chat'),
          HistoryConversation('old', 'group', title: 'Old team'),
        ],
        messages: [
          _message('live', 'l1', body: 'live words'),
          _message('old', 'o1', body: 'from bob'),
          _message('old', 'o2', body: 'my own words', sender: 'alice'),
          _message('old', 'o3', body: 'gone', expires: now + 600000),
        ],
        reactions: const [],
        pins: const [],
        starred: const {},
        preferences: const []).encode();

class _State extends AppState {
  _State(LocalStore store)
      : super(
            apiClientFactory: (_) => ApiClient(baseUrl: origin),
            cryptoService: _MlsStub(),
            localStore: store,
            syncServiceFactory: (_, __) => _QuietSync());
}

_State _state(LocalStore store) => _State(store)
  ..session = _session
  ..conversations = [
    Conversation(id: 'live', kind: 'dm', title: 'Live chat', createdBy: 'bob')
  ]
  ..conversationsLoaded = true;

Future<void> _prepare(LocalStore store) async {
  await store.saveSession(_session);
  await store.saveCryptoState(
      StoredCryptoState(
          counter: 1, stateKey: List.filled(32, 7), sealedState: [8]),
      0);
  await store.importHistorySnapshot(_snapshot(), _context());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late LocalStore store;
      EncryptedLocalDatabase? db;
      late Directory dir;
      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        dir = await Directory.systemTemp.createTemp('veritra-k2-copied-');
        db = null;
        store = sqlite
            ? SecureLocalStore(
                directoryProvider: () async => dir,
                databaseFactory: (_, __) =>
                    db ??= EncryptedLocalDatabase(NativeDatabase.memory()))
            : MemoryLocalStore();
        await _prepare(store);
      });
      tearDown(() async {
        await db?.close();
        await SecureLocalStore.releaseInstanceLocks();
        await dir.delete(recursive: true);
      });

      test('only conversations this device cannot open live are history-only',
          () async {
        final state = _state(store);
        expect(state.historyOnlyConversations, isEmpty,
            reason: 'nothing is shown before the descriptors are read');
        await state.refreshCopiedHistory();
        expect(state.historyOnlyConversations.map((c) => c.id), ['old']);
        expect(state.isHistoryOnly('live'), isFalse);
        expect(await state.historyOnlyMessages('live'), isEmpty,
            reason: 'a live chat is never read through the history path');

        final rows = await state.historyOnlyMessages('old',
            now: DateTime.fromMillisecondsSinceEpoch(now + 1200000));
        expect(rows.map((m) => m.body), ['from bob', 'my own words']);
        expect(
            (await state.historyOnlyMessages('old',
                    now: DateTime.fromMillisecondsSinceEpoch(now - 5000)))
                .map((m) => m.body),
            contains('gone'),
            reason: 'expiry is applied at read time');

        // Rejoining makes the chat live; it leaves the read-only list.
        state.conversations = [
          ...state.conversations,
          Conversation(id: 'old', kind: 'group', title: 'Old', createdBy: 'b')
        ];
        expect(state.historyOnlyConversations, isEmpty);
        expect(await state.historyOnlyMessages('old'), isEmpty);

        // Until the live list is known nothing is shown as history-only.
        state.conversationsLoaded = false;
        expect(state.historyOnlyConversations, isEmpty);
        state.dispose();
      });

      test('a community channel of a joined community is not history-only',
          () async {
        final state = _state(store);
        await state.refreshCopiedHistory();
        state.communities = [Community(id: 'c1', name: 'Club')];
        expect(state.historyOnlyConversations.map((c) => c.id), ['old']);
        state.dispose();
      });
    });
  }

  test('a session ended during the restore read never keeps its descriptors',
      () async {
    final store = _BlockingHistoryStore();
    await _prepare(store);
    final state = AppState(
        apiClientFactory: (_) => ApiClient(baseUrl: origin),
        cryptoService: TestOnlyCryptoService(),
        localStore: store,
        syncServiceFactory: (_, __) => _QuietSync());
    store.block = Completer<void>();
    final restoring = state.tryRestoreSession();
    await store.reading.future.timeout(const Duration(seconds: 5));
    state.dispose(); // ends the session generation mid-read
    store.block!.complete();
    await restoring;
    state.conversationsLoaded = true;
    expect(state.historyOnlyConversations, isEmpty);
  });

  test('community channels wait for the community list', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 7), sealedState: [8]),
        0);
    await store.importHistorySnapshot(
        HistorySnapshot(
            accountId: 'alice',
            sourceDeviceId: source,
            counter: 1,
            createdAt: now,
            conversations: const [
              HistoryConversation('ch', 'community_channel',
                  communityId: 'c1', channelId: 'k1', title: 'General'),
            ],
            messages: [
              _message('ch', 'c1')
            ],
            reactions: const [],
            pins: const [],
            starred: const {},
            preferences: const []).encode(),
        _context());
    final state = _state(store);
    await state.refreshCopiedHistory();
    expect(state.historyOnlyConversations, isEmpty,
        reason: 'communities are not known yet');
    state.communitiesLoaded = true;
    expect(state.historyOnlyConversations.map((c) => c.id), ['ch']);
    state.communities = [Community(id: 'c1', name: 'Club')];
    expect(state.historyOnlyConversations, isEmpty);
    state.dispose();
  });

  testWidgets('copied history opens read-only, with no composer or actions',
      (tester) async {
    final store = MemoryLocalStore();
    await tester.runAsync(() => _prepare(store));
    final state = _state(store);
    await tester.runAsync(state.refreshCopiedHistory);
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatListScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Old team'), findsNothing,
        reason: 'history-only chats are not mixed into the live list');
    await tester.tap(find.byTooltip(englishL10n.k2HistoryOnlyTitle));
    await tester.pumpAndSettle();
    expect(find.byType(CopiedHistoryListScreen), findsOneWidget);
    expect(find.text(englishL10n.k2HistoryOnlyNotice), findsOneWidget);
    expect(find.text('Live chat'), findsNothing);
    await tester.tap(find.text('Old team'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(CopiedHistoryScreen), findsOneWidget);
    expect(find.text('from bob'), findsOneWidget);
    expect(find.text('my own words'), findsOneWidget);
    expect(
        find.textContaining(englishL10n.k2HistoryOtherMember), findsNWidgets(2),
        reason: 'other senders are never named or looked up');
    expect(find.textContaining(englishL10n.detailsYou), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('the chat list offers no copied-history entry without one',
      (tester) async {
    final state = _state(MemoryLocalStore());
    await tester.pumpWidget(MaterialApp(home: ChatListScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.byTooltip(englishL10n.k2HistoryOnlyTitle), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

class _BlockingHistoryStore extends MemoryLocalStore {
  Completer<void>? block;
  final reading = Completer<void>();
  @override
  Future<HistoryNamespace> loadHistoryNamespace() async {
    final gate = block;
    if (gate != null) {
      if (!reading.isCompleted) reading.complete();
      await gate.future;
    }
    return super.loadHistoryNamespace();
  }
}

class _MlsStub implements MlsConversationCryptoService {
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
