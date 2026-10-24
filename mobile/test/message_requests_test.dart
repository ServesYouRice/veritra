import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

Conversation _dm(
  String id,
  String peer,
  String createdBy, {
  DateTime? lastMessageAt,
}) =>
    Conversation(
      id: id,
      kind: 'dm',
      peerAccountId: peer,
      peerUsername: peer.replaceFirst('acct_', ''),
      createdBy: createdBy,
      unreadCount: 1,
      createdAt: DateTime.utc(2026, 6, 1),
      lastMessageAt: lastMessageAt,
    );

Conversation _group(String id, String createdBy) => Conversation(
      id: id,
      kind: 'group',
      title: id,
      createdBy: createdBy,
      createdAt: DateTime.utc(2026, 6, 1),
    );

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  List<Conversation> list = <Conversation>[];
  final List<String> reads = <String>[];
  final List<String> left = <String>[];
  final List<String> blocked = <String>[];

  @override
  Future<List<Conversation>> conversations(String token) async => list;

  @override
  Future<void> markRead(String token, String conversationId, String id) async {
    reads.add(conversationId);
  }

  @override
  Future<BlockedAccount> blockAccount(String token, String accountId) async {
    blocked.add(accountId);
    return BlockedAccount(accountId: accountId);
  }

  // The server refuses to remove a member from anything but a group.
  @override
  Future<void> removeConversationMember(
    String token,
    String conversationId,
    String accountId,
  ) async {
    final conversation = list.firstWhere((c) => c.id == conversationId);
    if (!conversation.isGroup) {
      throw ApiException(403, '{"error":"forbidden"}');
    }
    left.add(conversationId);
    list = list.where((c) => c.id != conversationId).toList();
  }
}

class _FakeSync implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _events.close();
}

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

AppState _state(_Api api, LocalStore store) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _FakeSync(),
    )
      ..api = api
      ..session = _session;

Conversation _find(AppState state, String id) =>
    state.conversations.firstWhere((c) => c.id == id);

RequestBucket _bucket(AppState state, String id) =>
    state.requestBucket(_find(state, id));

void main() {
  test('a fresh device grandfathers nothing but what this account started',
      () async {
    final api = _Api()
      ..list = <Conversation>[
        _dm('old', 'acct_old', 'acct_old'),
        _dm('mine', 'acct_friend', 'acct_me'),
        _group('theirs', 'acct_old'),
      ];
    final state = _state(api, MemoryLocalStore());
    expect(state.requestStateLoaded, isFalse);
    await state.refreshConversations();
    expect(_bucket(state, 'old'), RequestBucket.request);
    expect(_bucket(state, 'mine'), RequestBucket.chat);
    expect(_bucket(state, 'theirs'), RequestBucket.request);
  });

  test('an upgrade keeps existing DMs and groups; new strangers are requests',
      () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveSnapshot(
      <Conversation>[
        _dm('old', 'acct_old', 'acct_old'),
        _group('oldgroup', 'acct_old'),
      ],
      <String, List<ReceivedMessageEnvelope>>{},
      0,
    );
    final api = _Api()
      ..list = <Conversation>[
        _dm('old', 'acct_old', 'acct_old'),
        _group('oldgroup', 'acct_old'),
        _dm('new', 'acct_stranger', 'acct_stranger'),
        _group('newgroup', 'acct_stranger'),
      ];
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _FakeSync(),
    );
    await state.tryRestoreSession();
    await state.refreshConversations();
    expect(_bucket(state, 'old'), RequestBucket.chat);
    expect(_bucket(state, 'oldgroup'), RequestBucket.chat);
    expect(_bucket(state, 'new'), RequestBucket.request);
    expect(_bucket(state, 'newgroup'), RequestBucket.request);
    state.dispose();
  });

  test('requests hold back receipts and attachments; accept persists',
      () async {
    final api = _Api()
      ..list = <Conversation>[
        _dm('new', 'acct_stranger', 'acct_stranger'),
        _group('g', 'acct_stranger'),
      ];
    final store = MemoryLocalStore();
    final state = _state(api, store);
    await state.refreshConversations();
    expect(_bucket(state, 'new'), RequestBucket.request);
    expect(_bucket(state, 'g'), RequestBucket.request);

    state.messagesByConversation['new'] = <ReceivedMessageEnvelope>[
      ReceivedMessageEnvelope.fromJson(<String, Object?>{
        'id': 'm1',
        'conversation_id': 'new',
        'sender_account_id': 'acct_stranger',
        'sender_device_id': 'd',
        'idempotency_key': 'm1',
        'ciphertext': '',
        'crypto_protocol': 'test',
        'created_at': '2026-06-02T12:30:00Z',
      }),
    ];
    await state.markNewestMessageRead('new');
    expect(api.reads, isEmpty);

    AttachmentEntry entry(String conversation) => AttachmentEntry(
          id: 'att',
          fileName: 'a.png',
          mediaType: 'image/png',
          plaintextSize: 10,
          ciphertextSize: 30,
          manifest: <String, Object?>{'conversation_id': conversation},
        );
    expect(state.loadAttachment(entry('new'), conversationId: 'new'),
        throwsA(isA<StateError>()));
    // The caller's conversation decides: a manifest naming a different (or
    // no) conversation is refused rather than trusted.
    expect(state.loadAttachment(entry('other'), conversationId: 'new'),
        throwsA(isA<StateError>()));
    expect(
        state.loadAttachment(
          AttachmentEntry(
            id: 'att',
            fileName: 'a.png',
            mediaType: 'image/png',
            plaintextSize: 10,
            ciphertextSize: 30,
            manifest: const <String, Object?>{},
          ),
          conversationId: 'new',
        ),
        throwsA(isA<StateError>()));

    expect(await state.acceptMessageRequest('new'), isTrue);
    expect(await state.acceptMessageRequest('g'), isTrue);
    expect(_bucket(state, 'new'), RequestBucket.chat);
    expect(_bucket(state, 'g'), RequestBucket.chat);
    await state.markNewestMessageRead('new');
    expect(api.reads, <String>['new']);

    // Acceptance survives a restart (same encrypted local store).
    final restarted = _state(api, store);
    await restarted.refreshConversations();
    expect(_bucket(restarted, 'new'), RequestBucket.chat);
    expect(_bucket(restarted, 'g'), RequestBucket.chat);
  });

  test('delete on a DM never leaves it: it is hidden until newer activity',
      () async {
    final api = _Api()
      ..list = <Conversation>[_dm('new', 'acct_stranger', 'acct_stranger')];
    final store = MemoryLocalStore();
    final state = _state(api, store);
    await state.refreshConversations();

    expect(await state.deleteMessageRequest('new'), isTrue);
    expect(api.left, isEmpty);
    expect(_bucket(state, 'new'), RequestBucket.hidden);

    // Still hidden after a restart and a refresh with no new activity.
    final restarted = _state(api, store);
    await restarted.refreshConversations();
    expect(_bucket(restarted, 'new'), RequestBucket.hidden);

    // A newer message brings it back as a request, never as a chat.
    api.list = <Conversation>[
      _dm('new', 'acct_stranger', 'acct_stranger',
          lastMessageAt: DateTime.now().add(const Duration(minutes: 5))),
    ];
    await restarted.refreshConversations();
    expect(_bucket(restarted, 'new'), RequestBucket.request);
  });

  test('block on a DM blocks, hides, and never returns it to the list',
      () async {
    final api = _Api()
      ..list = <Conversation>[_dm('new', 'acct_stranger', 'acct_stranger')];
    final state = _state(api, MemoryLocalStore());
    await state.refreshConversations();

    expect(await state.blockMessageRequest('new'), isTrue);
    expect(api.blocked, <String>['acct_stranger']);
    expect(api.left, isEmpty);
    expect(_bucket(state, 'new'), RequestBucket.hidden);

    api.list = <Conversation>[
      _dm('new', 'acct_stranger', 'acct_stranger',
          lastMessageAt: DateTime.now().add(const Duration(minutes: 5))),
    ];
    await state.refreshConversations();
    expect(_bucket(state, 'new'), RequestBucket.hidden);
    // A blocked sender cannot be accepted either.
    expect(await state.acceptMessageRequest('new'), isFalse);
  });

  test('a stranger group is a request; delete and block leave it for real',
      () async {
    final api = _Api()
      ..list = <Conversation>[
        _group('g1', 'acct_stranger'),
        _group('g2', 'acct_other'),
        _group('mine', 'acct_me'),
      ];
    final state = _state(api, MemoryLocalStore());
    await state.refreshConversations();
    expect(_bucket(state, 'mine'), RequestBucket.chat);

    expect(await state.deleteMessageRequest('g1'), isTrue);
    expect(api.left, <String>['g1']);

    expect(await state.blockMessageRequest('g2'), isTrue);
    expect(api.blocked, <String>['acct_other']);
    expect(api.left, <String>['g1', 'g2']);
    expect(state.conversations.map((c) => c.id), <String>['mine']);
  });

  test('a group from an accepted peer is not a request', () async {
    final api = _Api()
      ..list = <Conversation>[
        _dm('new', 'acct_pal', 'acct_pal'),
        _group('g', 'acct_pal'),
      ];
    final state = _state(api, MemoryLocalStore());
    await state.refreshConversations();
    expect(_bucket(state, 'g'), RequestBucket.request);
    await state.acceptMessageRequest('new');
    expect(_bucket(state, 'g'), RequestBucket.chat);
  });

  test('starting a conversation with the peer accepts their request', () async {
    final api = _Api()
      ..list = <Conversation>[_dm('new', 'acct_stranger', 'acct_stranger')];
    final state = _state(api, MemoryLocalStore());
    await state.refreshConversations();
    expect(_bucket(state, 'new'), RequestBucket.request);
    final started = await state.startConversation(
      kind: 'dm',
      memberAccountIds: <String>['acct_stranger'],
    );
    expect(started?.id, 'new');
    expect(_bucket(state, 'new'), RequestBucket.chat);
  });

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      );

  testWidgets('chat list shows Requests; delete hides without a server call',
      (tester) async {
    final api = _Api()
      ..list = <Conversation>[
        _dm('mine', 'acct_old', 'acct_me'),
        _dm('new', 'acct_stranger', 'acct_stranger'),
      ];
    final state = _state(api, MemoryLocalStore());
    await state.refreshConversations();

    await tester.pumpWidget(app(ChatListScreen(state: state)));
    await tester.pump();

    expect(find.text('REQUESTS (1)'), findsOneWidget);
    await tester.tap(find.textContaining('stranger'));
    await tester.pumpAndSettle();
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    // Nothing was read or fetched by opening it.
    expect(api.reads, isEmpty);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.left, isEmpty);
    expect(find.textContaining('stranger'), findsNothing);
    expect(find.text('REQUESTS (1)'), findsNothing);
  });

  testWidgets('a request opened directly (search, wide pane) shows the request',
      (tester) async {
    final api = _Api()
      ..list = <Conversation>[_dm('new', 'acct_stranger', 'acct_stranger')];
    final state = _state(api, MemoryLocalStore());
    await state.refreshConversations();

    await tester.pumpWidget(
      app(ChatScreen(state: state, conversationId: 'new')),
    );
    await tester.pump();
    expect(find.text('Accept'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Accept'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Accept'), findsNothing);
    expect(_bucket(state, 'new'), RequestBucket.chat);
  });
}
