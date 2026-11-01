// D68: while sends to a conversation wait for a removed member's MLS
// commit, the chat says so and offers no second send of the same text.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/l10n/app_localizations_en.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  int sends = 0;

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      const <ConversationMember>[];

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      ConversationMute(muted: false);

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    sends++;
  }

  @override
  Future<void> markRead(
      String token, String conversationId, String messageId) async {}
}

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('a held conversation shows why and does not send again',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
        username: 'owner',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ];
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(state: state, conversationId: 'conv_1'),
    ));
    await tester.pumpAndSettle();
    final notice = AppLocalizationsEn().chatRemovalHoldNotice;
    expect(find.text(notice), findsNothing);

    state.debugHoldSendsForRemoval('conv_1');
    // The send control spins while a send is pending, so nothing settles.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(notice), findsOneWidget);

    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'again',
      selection: TextSelection.collapsed(offset: 5),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'again',
        reason: 'the send control is off while sends are held');
    expect(api.sends, 0);
    // Lets the draft debounce run out before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  });
}
