// D134 (bug-hunt c6ed/Q-006): a conversation paused by an encryption update
// that could not be sent offers Retry and Discard, so it never stays stuck.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

/// Records the person's choice instead of acting on an outbox.
class _State extends AppState {
  _State(_Api api)
      : super(
          apiClientFactory: (_) => api,
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _Sync(),
        );

  final List<String> choices = <String>[];

  @override
  Future<void> retryMlsUpdate(String conversationId) async {
    choices.add('retry:$conversationId');
    debugMlsConversationFailed(const <String>{});
  }

  @override
  Future<void> discardMlsUpdate(String conversationId) async {
    choices.add('discard:$conversationId');
    debugMlsConversationFailed(const <String>{});
  }
}

void main() {
  Future<_State> open(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final api = _Api();
    final state = _State(api)
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_me',
        deviceId: 'dev_me',
        username: 'me',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_a', kind: 'group'),
      ];
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(state: state, conversationId: 'conv_a'),
    ));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  }

  final l10n = AppLocalizationsEn();
  const retry = ValueKey('mls-paused-retry');
  const discard = ValueKey('mls-paused-discard');

  testWidgets('the paused notice offers Retry, which resumes the chat',
      (tester) async {
    final state = await open(tester);
    expect(find.text(l10n.chatPausedNotice), findsNothing);

    state.debugMlsConversationFailed(const <String>{'conv_a'});
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatPausedNotice), findsOneWidget);
    expect(
        find.widgetWithText(TextButton, l10n.bannerTryAgain), findsOneWidget);
    expect(find.widgetWithText(TextButton, l10n.chatPausedDiscard),
        findsOneWidget);

    await tester.tap(find.byKey(retry));
    await tester.pumpAndSettle();
    expect(state.choices, <String>['retry:conv_a']);
    expect(find.text(l10n.chatPausedNotice), findsNothing);
    await close(tester);
  });

  testWidgets('the paused notice offers Discard, which resumes the chat',
      (tester) async {
    final state = await open(tester);
    state.debugMlsConversationFailed(const <String>{'conv_a'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(discard));
    await tester.pumpAndSettle();
    expect(state.choices, <String>['discard:conv_a']);
    expect(find.text(l10n.chatPausedNotice), findsNothing);
    await close(tester);
  });
}
