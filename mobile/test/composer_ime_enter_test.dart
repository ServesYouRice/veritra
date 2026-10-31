// Desktop Enter-to-send must not fire while an IME is composing
// (C-572d3de039a9): Enter then confirms the candidate, and the draft stays.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
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
  testWidgets('Enter during IME composition confirms instead of sending',
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

    String composerText() =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    await tester.showKeyboard(find.byType(TextField));
    // An IME is composing "ni" (for example pinyin before choosing 你).
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    ));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(composerText(), 'ni', reason: 'composing Enter must not send');
    expect(api.sends, 0);

    // The candidate is committed: composing ends, and Enter sends again.
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '你',
      selection: TextSelection.collapsed(offset: 1),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(composerText(), isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });
}
