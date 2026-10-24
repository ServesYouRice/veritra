import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

Conversation _dm(String id, String peer, String createdBy) => Conversation(
      id: id,
      kind: 'dm',
      peerAccountId: peer,
      peerUsername: peer.replaceFirst('acct_', ''),
      createdBy: createdBy,
      unreadCount: 1,
    );

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  List<Conversation> list = <Conversation>[];
  final List<String> reads = <String>[];
  final List<String> left = <String>[];

  @override
  Future<List<Conversation>> conversations(String token) async => list;

  @override
  Future<void> markRead(String token, String conversationId, String id) async {
    reads.add(conversationId);
  }

  @override
  Future<void> removeConversationMember(
    String token,
    String conversationId,
    String accountId,
  ) async {
    left.add(conversationId);
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

AppState _state(_Api api, LocalStore store) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _FakeSync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_me',
        deviceId: 'dev_me',
      );

void main() {
  test('strangers wait as requests; existing chats are kept; accept persists',
      () async {
    final api = _Api()
      ..list = <Conversation>[_dm('old', 'acct_old', 'acct_old')];
    final store = MemoryLocalStore();
    final state = _state(api, store);

    // First run: what already exists is grandfathered in.
    await state.refreshConversations();
    expect(state.isMessageRequest(state.conversations.single), isFalse);

    api.list = <Conversation>[
      _dm('old', 'acct_old', 'acct_old'),
      _dm('mine', 'acct_friend', 'acct_me'),
      _dm('new', 'acct_stranger', 'acct_stranger'),
    ];
    await state.refreshConversations();
    bool request(String id) => state
        .isMessageRequest(state.conversations.firstWhere((c) => c.id == id));
    expect(request('old'), isFalse);
    expect(request('mine'), isFalse);
    expect(request('new'), isTrue);

    // No read receipt while it is a request.
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

    // No attachment download while it is a request.
    final entry = AttachmentEntry(
      id: 'att',
      fileName: 'a.png',
      mediaType: 'image/png',
      plaintextSize: 10,
      ciphertextSize: 30,
      manifest: <String, Object?>{'conversation_id': 'new'},
    );
    expect(state.loadAttachment(entry), throwsA(isA<StateError>()));

    await state.acceptMessageRequest('new');
    expect(request('new'), isFalse);
    await state.markNewestMessageRead('new');
    expect(api.reads, <String>['new']);

    // Acceptance survives a restart (same encrypted local store).
    final restarted = _state(api, store);
    await restarted.refreshConversations();
    expect(
      restarted.isMessageRequest(
          restarted.conversations.firstWhere((c) => c.id == 'new')),
      isFalse,
    );
  });

  testWidgets('chat list shows Requests; opening one offers the three actions',
      (tester) async {
    final api = _Api()
      ..list = <Conversation>[_dm('old', 'acct_old', 'acct_old')];
    final state = _state(api, MemoryLocalStore());
    await state.refreshConversations();
    api.list = <Conversation>[
      _dm('old', 'acct_old', 'acct_old'),
      _dm('new', 'acct_stranger', 'acct_stranger'),
    ];
    await state.refreshConversations();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatListScreen(state: state),
      ),
    );
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
    expect(api.left, <String>['new']);
  });
}
