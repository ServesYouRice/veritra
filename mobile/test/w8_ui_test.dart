import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/message_ticks.dart';
import 'package:private_messenger/features/chat/formatted_message.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

void main() {
  testWidgets(
      'spoilers stay concealed until tapped and reset on a changed message',
      (tester) async {
    Widget app(String text) => MaterialApp(
        home: Scaffold(
            body: FormattedMessage(
                text: text,
                formatJson: jsonEncode({
                  'entities': [
                    {'type': 'spoiler', 'offset': 0, 'length': text.length}
                  ]
                }))));
    await tester.pumpWidget(app('secret'));
    String visible() => tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!
        .toPlainText();
    expect(visible(), '█' * 6);
    await tester.tap(find.byType(SelectableText));
    await tester.pump();
    expect(visible(), 'secret');
    await tester.pumpWidget(app('different'));
    expect(visible(), '█' * 9);
  });

  testWidgets(
      'message actions scroll, star browsing works, delete for me hides the row',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.byType(FormattedMessage), findsOneWidget);
    await tester.tap(find.byType(FormattedMessage),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(englishL10n.w8Star));
    await tester.tap(find.text(englishL10n.w8Star));
    await tester.pumpAndSettle();
    expect(await store.loadStarred(), {'dev:t'});
    await tester.tap(find.byTooltip(englishL10n.w8StarredMessages));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.w8StarredMessages), findsOneWidget);
    expect(find.byIcon(Icons.star), findsWidgets);
    await tester.tap(find.text('hello').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FormattedMessage),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(englishL10n.w8DeleteForMe));
    await tester.tap(find.text(englishL10n.w8DeleteForMe));
    await tester.pumpAndSettle();
    expect(find.byType(FormattedMessage), findsNothing);
    expect(await store.loadStarred(), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
      'restored own bubbles show snapshot provenance without live ticks',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store, messageState: LocalMessageState.restored);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.k2CopiedHistory), findsOneWidget);
    expect(
        tester
            .widget<MessageTickBuilder>(find.byType(MessageTickBuilder))
            .enabled,
        false);
    expect(find.byType(MessageTickIcon), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('archived chats remain reachable through the archive switch',
      (tester) async {
    final state = _state();
    await state.setConversationArchived('conv', true);
    await tester.pumpWidget(MaterialApp(home: ChatListScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsNothing);
    await tester.tap(find.byTooltip(englishL10n.w8ArchivedChats));
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsOneWidget);
    expect(find.text(englishL10n.w8ArchivedChats), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

class _UiState extends AppState {
  _UiState()
      : super(
            apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
            cryptoService: _MlsStub(),
            localStore: MemoryLocalStore(),
            syncServiceFactory: (_, __) => _QuietSync());
  LocalStore? localStoreOverride;
  @override
  LocalStore get localStore => localStoreOverride ?? super.localStore;
}

_UiState _state() => _UiState()
  ..session = const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'alice',
      deviceId: 'dev')
  ..conversations = [
    Conversation(id: 'conv', kind: 'dm', title: 'Team', createdBy: 'alice')
  ]
  ..conversationsLoaded = true;
Future<void> _seed(LocalStore store,
    {String messageState = LocalMessageState.received}) async {
  await store.saveCryptoState(
      StoredCryptoState(
          counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
      0);
  await store.commitMlsTransition(MlsStateTransition(
      messageId: 'seed',
      conversationId: 'conv',
      expectedCounter: 1,
      expectedCursor: 0,
      state: StoredCryptoState(
          counter: 2, stateKey: List.filled(32, 1), sealedState: [2]),
      cursor: 1,
      messageEffects: [
        InsertMessageEffect(
            key: 'dev:t',
            conversationId: 'conv',
            senderAccountId: 'alice',
            senderDeviceId: 'dev',
            kind: LocalMessageKind.text,
            body: 'hello',
            createdAt: 1,
            state: messageState)
      ]));
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
